#!/usr/bin/env python3
"""Evaluate local text translation quality using synthetic fixtures."""

from __future__ import annotations

import argparse
from collections import Counter
import difflib
import json
import os
import re
import select
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURES = REPO_ROOT / "eval" / "fixtures" / "translation_text_cases.jsonl"
DEFAULT_REPORTS_DIR = REPO_ROOT / "eval" / "reports"
WORKER_SCRIPT = REPO_ROOT / "Sources" / "SubsApp" / "Resources" / "opus_mt_translate.py"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Subs"
DEFAULT_PYTHON = APP_SUPPORT / "Runtime" / "opus" / "bin" / "python"
DEFAULT_OPUS_MODELS_DIR = APP_SUPPORT / "Models" / "opus-mt"
DEFAULT_BAKEOFF_MODELS_DIR = APP_SUPPORT / "Models" / "translation-bakeoff"
DEFAULT_M2M100_MODEL_DIR = DEFAULT_BAKEOFF_MODELS_DIR / "m2m100-418m"
DEFAULT_WORKER_TIMEOUT_SECONDS = int(os.environ.get("SUBS_TRANSLATION_EVAL_TIMEOUT_SECONDS", "180"))
OPUS_BACKEND = "opus-mt"
M2M100_BACKEND = "m2m100-418m"
ALL_BACKEND = "all"
BACKEND_CHOICES = [OPUS_BACKEND, M2M100_BACKEND, ALL_BACKEND]

M2M100_WORKER_CODE = r"""
import json
import os
import sys
from typing import Any, Dict, Tuple

_MODEL_CACHE: Dict[str, Tuple[Any, Any]] = {}


def response(request_id: str, ok: bool, translated_text: str = "", error: str = "") -> str:
    payload = {"id": request_id, "ok": ok}
    if ok:
        payload["translatedText"] = translated_text
    else:
        payload["error"] = error
    return json.dumps(payload, ensure_ascii=False)


def validate_runtime() -> None:
    try:
        import sentencepiece  # noqa: F401
        import torch  # noqa: F401
        from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer  # noqa: F401
    except ImportError as error:
        raise RuntimeError(
            "The local M2M100 eval backend requires Python packages "
            "'transformers[torch]' and 'sentencepiece'. "
            f"Run script/setup_m2m100_bakeoff.sh and retry. Import error: {error}"
        ) from error


def load_model(model_path: str) -> Tuple[Any, Any]:
    if not model_path or not os.path.isdir(model_path):
        raise RuntimeError(
            "Local M2M100 model folder was not found at "
            f"{model_path!r}. Run script/setup_m2m100_bakeoff.sh and retry."
        )

    if model_path in _MODEL_CACHE:
        return _MODEL_CACHE[model_path]

    from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

    tokenizer = M2M100Tokenizer.from_pretrained(model_path, local_files_only=True)
    model = M2M100ForConditionalGeneration.from_pretrained(model_path, local_files_only=True)
    model.eval()
    _MODEL_CACHE[model_path] = (tokenizer, model)
    return tokenizer, model


def translate(request: Dict[str, Any]) -> str:
    source_text = request.get("sourceText", "")
    if not source_text.strip():
        return ""

    validate_runtime()
    tokenizer, model = load_model(request.get("modelPath", ""))
    tokenizer.src_lang = request.get("sourceLanguageCode", "")
    inputs = tokenizer(source_text, return_tensors="pt", truncation=True)
    import torch

    with torch.no_grad():
        generated = model.generate(
            **inputs,
            forced_bos_token_id=tokenizer.get_lang_id(request.get("targetLanguageCode", "en")),
            max_new_tokens=80,
        )
    return tokenizer.batch_decode(generated, skip_special_tokens=True)[0]


def run_worker() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue

        request_id = ""
        try:
            request = json.loads(line)
            request_id = request.get("id", "")
            print(response(request_id, True, translated_text=translate(request)), flush=True)
        except Exception as error:
            print(response(request_id, False, error=str(error)), flush=True)


run_worker()
"""


@dataclass
class EvalCase:
    id: str
    language_pair: str
    source_text: str
    reference_english: str
    required_terms: List[str]
    required_term_groups: List[List[str]]
    forbidden_terms: List[str]
    notes: str


class TranslationWorker:
    def __init__(self, python_path: Path, command: Sequence[str], worker_name: str) -> None:
        self.python_path = python_path
        self.command = list(command)
        self.worker_name = worker_name
        self.process: Optional[subprocess.Popen[str]] = None

    def __enter__(self) -> "TranslationWorker":
        if not self.python_path.exists():
            raise RuntimeError(
                f"{self.worker_name} Python runtime was not found at {self.python_path}. "
                "Run ./script/setup_opus_mt.sh, ./script/setup_m2m100_bakeoff.sh, or set SUBS_PYTHON."
            )

        self.process = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self.process is None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()

    def translate(self, request: Dict[str, Any], timeout_seconds: int = DEFAULT_WORKER_TIMEOUT_SECONDS) -> Dict[str, Any]:
        if self.process is None or self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError(f"{self.worker_name} worker is not running.")

        try:
            self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            self.process.stdin.flush()
        except OSError as error:
            raise RuntimeError(f"{self.worker_name} worker pipe write failed: {error}") from error

        ready, _, _ = select.select([self.process.stdout], [], [], timeout_seconds)
        if not ready:
            self.process.kill()
            self.process.wait(timeout=5)
            self.process = None
            raise RuntimeError(f"{self.worker_name} worker timed out after {timeout_seconds} seconds.")

        line = self.process.stdout.readline()
        if not line:
            stderr = ""
            if self.process.stderr is not None:
                stderr = self.process.stderr.read().strip()
            raise RuntimeError(stderr or f"{self.worker_name} worker exited without a response.")

        return json.loads(line)

    @property
    def pid(self) -> Optional[int]:
        return self.process.pid if self.process is not None else None


def require_string(payload: Dict[str, Any], key: str, line_number: int) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Fixture line {line_number} must include non-empty string field {key!r}.")
    return value


def require_string_list(payload: Dict[str, Any], key: str, line_number: int) -> List[str]:
    value = payload.get(key, [])
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        raise ValueError(f"Fixture line {line_number} field {key!r} must be a list of non-empty strings.")
    return value


def require_term_groups(payload: Dict[str, Any], line_number: int) -> List[List[str]]:
    value = payload.get("requiredTermGroups", [])
    if not isinstance(value, list):
        raise ValueError(f"Fixture line {line_number} field 'requiredTermGroups' must be a list of lists.")

    groups: List[List[str]] = []
    for index, group in enumerate(value, start=1):
        if not isinstance(group, list) or not all(isinstance(term, str) and term.strip() for term in group):
            raise ValueError(
                f"Fixture line {line_number} requiredTermGroups item {index} must be a list of non-empty strings."
            )
        if not group:
            raise ValueError(f"Fixture line {line_number} requiredTermGroups item {index} must not be empty.")
        groups.append(group)
    return groups


def load_cases(path: Path) -> List[EvalCase]:
    cases: List[EvalCase] = []
    seen_ids: set[str] = set()

    if not path.exists():
        raise ValueError(f"Fixture file was not found at {path}.")

    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            try:
                payload = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"Fixture line {line_number} is not valid JSON: {error}") from error

            if not isinstance(payload, dict):
                raise ValueError(f"Fixture line {line_number} must be a JSON object.")

            case_id = require_string(payload, "id", line_number)
            if case_id in seen_ids:
                raise ValueError(f"Duplicate fixture id on line {line_number}: {case_id}")
            seen_ids.add(case_id)

            language_pair = require_string(payload, "languagePair", line_number)
            if language_pair not in {"th-en", "ja-en"}:
                raise ValueError(f"Unsupported languagePair on line {line_number}: {language_pair}")

            notes = payload.get("notes", "")
            if not isinstance(notes, str):
                raise ValueError(f"Fixture line {line_number} field 'notes' must be a string when present.")

            cases.append(
                EvalCase(
                    id=case_id,
                    language_pair=language_pair,
                    source_text=require_string(payload, "sourceText", line_number),
                    reference_english=require_string(payload, "referenceEnglish", line_number),
                    required_terms=require_string_list(payload, "requiredTerms", line_number),
                    required_term_groups=require_term_groups(payload, line_number),
                    forbidden_terms=require_string_list(payload, "forbiddenTerms", line_number),
                    notes=notes,
                )
            )

    if not cases:
        raise ValueError(f"Fixture file has no runnable cases: {path}")
    return cases


def filter_cases(cases: Sequence[EvalCase], case_id: Optional[str], language_pair: Optional[str]) -> List[EvalCase]:
    filtered = list(cases)
    if case_id:
        filtered = [case for case in filtered if case.id == case_id]
    if language_pair:
        filtered = [case for case in filtered if case.language_pair == language_pair]
    if not filtered:
        filters = []
        if case_id:
            filters.append(f"--case {case_id}")
        if language_pair:
            filters.append(f"--language-pair {language_pair}")
        raise ValueError(f"No eval cases matched {' '.join(filters)}.")
    return filtered


def python_path() -> Path:
    return Path(os.environ.get("SUBS_PYTHON", str(DEFAULT_PYTHON))).expanduser()


def model_path(language_pair: str) -> Path:
    pair_env = f"SUBS_OPUS_MT_MODEL_{language_pair.replace('-', '_').upper()}"
    if os.environ.get(pair_env):
        return Path(os.environ[pair_env]).expanduser()
    if os.environ.get("SUBS_OPUS_MT_MODELS_DIR"):
        return Path(os.environ["SUBS_OPUS_MT_MODELS_DIR"]).expanduser() / language_pair
    return DEFAULT_OPUS_MODELS_DIR / language_pair


def m2m100_model_path() -> Path:
    if os.environ.get("SUBS_M2M100_418M_MODEL"):
        return Path(os.environ["SUBS_M2M100_418M_MODEL"]).expanduser()
    if os.environ.get("SUBS_TRANSLATION_BAKEOFF_MODELS_DIR"):
        return Path(os.environ["SUBS_TRANSLATION_BAKEOFF_MODELS_DIR"]).expanduser() / "m2m100-418m"
    return DEFAULT_M2M100_MODEL_DIR


def selected_backends(backend: str) -> List[str]:
    if backend == ALL_BACKEND:
        return [OPUS_BACKEND, M2M100_BACKEND]
    return [backend]


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9\s]", " ", text.lower())).strip()


def contains_term(text: str, term: str) -> bool:
    return normalize(term) in normalize(text)


def term_group_label(group: Sequence[str]) -> str:
    return " / ".join(group)


def missing_required_term_groups(text: str, groups: Sequence[Sequence[str]]) -> List[str]:
    return [term_group_label(group) for group in groups if not any(contains_term(text, term) for term in group)]


def score_case(case: EvalCase, translated_text: str, latency_ms: int, error: Optional[str]) -> Dict[str, Any]:
    missing_required = [term for term in case.required_terms if not contains_term(translated_text, term)]
    missing_groups = missing_required_term_groups(translated_text, case.required_term_groups)
    forbidden_hits = [term for term in case.forbidden_terms if contains_term(translated_text, term)]
    similarity = difflib.SequenceMatcher(None, normalize(case.reference_english), normalize(translated_text)).ratio()
    checks_passed = bool(translated_text.strip()) and not missing_required and not missing_groups and not forbidden_hits and error is None

    return {
        "backend": "",
        "backendName": "",
        "id": case.id,
        "languagePair": case.language_pair,
        "sourceText": case.source_text,
        "referenceEnglish": case.reference_english,
        "translatedText": translated_text,
        "requiredTerms": case.required_terms,
        "requiredTermGroups": case.required_term_groups,
        "missingRequiredTerms": missing_required,
        "missingRequiredTermGroups": missing_groups,
        "forbiddenTerms": case.forbidden_terms,
        "forbiddenTermHits": forbidden_hits,
        "similarity": round(similarity, 4),
        "latencyMs": latency_ms,
        "nonEmpty": bool(translated_text.strip()),
        "checksPassed": checks_passed,
        "error": error,
        "notes": case.notes,
        "reviewDecision": "",
        "reviewNotes": "",
    }


class TranslationBackend:
    id: str
    display_name: str

    def __enter__(self) -> "TranslationBackend":
        raise NotImplementedError

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        raise NotImplementedError

    def translate(self, case: EvalCase) -> tuple[str, Optional[str], int]:
        raise NotImplementedError

    @property
    def pid(self) -> Optional[int]:
        raise NotImplementedError

    @property
    def models(self) -> Dict[str, str]:
        raise NotImplementedError


class OPUSMTBackend(TranslationBackend):
    id = OPUS_BACKEND
    display_name = "OPUS-MT local runtime"

    def __init__(self, python: Path) -> None:
        self.python = python
        self.worker: Optional[TranslationWorker] = None

    def __enter__(self) -> "OPUSMTBackend":
        if not WORKER_SCRIPT.exists():
            raise RuntimeError(f"OPUS-MT worker script was not found at {WORKER_SCRIPT}.")
        self.worker = TranslationWorker(
            self.python,
            [str(self.python), str(WORKER_SCRIPT), "--worker"],
            "OPUS-MT",
        )
        self.worker.__enter__()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self.worker is not None:
            self.worker.__exit__(exc_type, exc, traceback)

    @property
    def pid(self) -> Optional[int]:
        return self.worker.pid if self.worker is not None else None

    @property
    def models(self) -> Dict[str, str]:
        return {
            "th-en": str(model_path("th-en")),
            "ja-en": str(model_path("ja-en")),
        }

    def translate(self, case: EvalCase) -> tuple[str, Optional[str], int]:
        if self.worker is None:
            raise RuntimeError("OPUS-MT worker is not running.")

        source_language, target_language = case.language_pair.split("-", maxsplit=1)
        path = model_path(case.language_pair)
        if not path.exists():
            raise RuntimeError(
                f"Model folder for {case.language_pair} was not found at {path}. "
                "Run ./script/setup_opus_mt.sh or set SUBS_OPUS_MT_MODELS_DIR."
            )

        request = {
            "id": case.id,
            "command": "translate",
            "sourceText": case.source_text,
            "sourceLanguageCode": source_language,
            "targetLanguageCode": target_language,
            "modelPath": str(path),
        }
        start = time.monotonic()
        try:
            response = self.worker.translate(request)
        except RuntimeError as error:
            latency_ms = int((time.monotonic() - start) * 1000)
            return "", str(error), latency_ms
        latency_ms = int((time.monotonic() - start) * 1000)

        if response.get("ok"):
            return response.get("translatedText", ""), None, latency_ms
        return "", response.get("error", "Unknown OPUS-MT worker error."), latency_ms


class M2M100Backend(TranslationBackend):
    id = M2M100_BACKEND
    display_name = "M2M100 418M eval runtime"

    def __init__(self, python: Path) -> None:
        self.python = python
        self.worker: Optional[TranslationWorker] = None

    def __enter__(self) -> "M2M100Backend":
        self.worker = TranslationWorker(
            self.python,
            [str(self.python), "-u", "-c", M2M100_WORKER_CODE],
            "M2M100 418M",
        )
        self.worker.__enter__()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self.worker is not None:
            self.worker.__exit__(exc_type, exc, traceback)

    @property
    def pid(self) -> Optional[int]:
        return self.worker.pid if self.worker is not None else None

    @property
    def models(self) -> Dict[str, str]:
        return {"m2m100-418m": str(m2m100_model_path())}

    def translate(self, case: EvalCase) -> tuple[str, Optional[str], int]:
        if self.worker is None:
            raise RuntimeError("M2M100 418M worker is not running.")

        source_language, target_language = case.language_pair.split("-", maxsplit=1)
        path = m2m100_model_path()
        if not path.exists():
            raise RuntimeError(
                f"M2M100 418M model folder was not found at {path}. "
                "Run ./script/setup_m2m100_bakeoff.sh or set SUBS_M2M100_418M_MODEL."
            )

        request = {
            "id": case.id,
            "sourceText": case.source_text,
            "sourceLanguageCode": source_language,
            "targetLanguageCode": target_language,
            "modelPath": str(path),
        }
        start = time.monotonic()
        try:
            response = self.worker.translate(request)
        except RuntimeError as error:
            latency_ms = int((time.monotonic() - start) * 1000)
            return "", str(error), latency_ms
        latency_ms = int((time.monotonic() - start) * 1000)

        if response.get("ok"):
            return response.get("translatedText", ""), None, latency_ms
        return "", response.get("error", "Unknown M2M100 418M worker error."), latency_ms


def make_backend(backend_id: str, python: Path) -> TranslationBackend:
    if backend_id == OPUS_BACKEND:
        return OPUSMTBackend(python)
    if backend_id == M2M100_BACKEND:
        return M2M100Backend(python)
    raise ValueError(f"Unsupported backend: {backend_id}")


def run_backend_eval(backend_id: str, cases: Sequence[EvalCase], python: Path) -> Dict[str, Any]:
    results: List[Dict[str, Any]] = []
    worker_pid: Optional[int] = None
    backend_name = backend_id
    models: Dict[str, str] = {}

    with make_backend(backend_id, python) as backend:
        worker_pid = backend.pid
        backend_name = backend.display_name
        models = backend.models
        for index, case in enumerate(cases, start=1):
            translated_text, error, latency_ms = backend.translate(case)
            result = score_case(case, translated_text, latency_ms, error)
            result["backend"] = backend.id
            result["backendName"] = backend.display_name
            results.append(result)
            print(f"[{backend.id} {index}] {case.id} ({case.language_pair}): {latency_ms} ms", flush=True)

    summary = summarize_results(results)

    return {
        "id": backend_id,
        "name": backend_name,
        "workerPid": worker_pid,
        "models": models,
        "summary": summary["overall"],
        "languagePairSummaries": summary["languagePairs"],
        "termSummaries": summary["terms"],
        "slowestCases": summary["slowestCases"],
        "results": results,
    }


def run_eval(cases: Sequence[EvalCase], python: Path, backend_choice: str) -> Dict[str, Any]:
    started_at = datetime.now(timezone.utc)
    backend_reports = [run_backend_eval(backend_id, cases, python) for backend_id in selected_backends(backend_choice)]
    results = [result for backend_report in backend_reports for result in backend_report["results"]]
    summary = summarize_results(results)

    return {
        "startedAt": started_at.isoformat(),
        "finishedAt": datetime.now(timezone.utc).isoformat(),
        "runtime": {
            "python": str(python),
            "opusWorkerScript": str(WORKER_SCRIPT),
            "models": {
                "th-en": str(model_path("th-en")),
                "ja-en": str(model_path("ja-en")),
                "m2m100-418m": str(m2m100_model_path()),
            },
        },
        "selectedBackends": selected_backends(backend_choice),
        "summary": summary["overall"],
        "backendSummaries": summary["backends"],
        "backendLanguagePairSummaries": summary["backendLanguagePairs"],
        "languagePairSummaries": summary["languagePairs"],
        "termSummaries": summary["terms"],
        "slowestCases": summary["slowestCases"],
        "backendReports": backend_reports,
        "results": results,
    }


def summarize_result_group(results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    total = len(results)
    passed = sum(1 for result in results if result["checksPassed"])
    average_similarity = sum(result["similarity"] for result in results) / total if total else 0
    average_latency = sum(result["latencyMs"] for result in results) / total if total else 0

    return {
        "total": total,
        "passed": passed,
        "failed": total - passed,
        "averageSimilarity": round(average_similarity, 4),
        "averageLatencyMs": round(average_latency, 1),
    }


def summarize_results(results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    missing_terms: Counter[str] = Counter()
    forbidden_hits: Counter[str] = Counter()

    for result in results:
        missing_terms.update(result["missingRequiredTerms"])
        missing_terms.update(result["missingRequiredTermGroups"])
        forbidden_hits.update(result["forbiddenTermHits"])

    language_pairs = {
        language_pair: summarize_result_group([result for result in results if result["languagePair"] == language_pair])
        for language_pair in sorted({result["languagePair"] for result in results})
    }
    backends = {
        backend: summarize_result_group([result for result in results if result["backend"] == backend])
        for backend in sorted({result["backend"] for result in results})
    }
    backend_language_pairs = {
        backend: {
            language_pair: summarize_result_group(
                [
                    result
                    for result in results
                    if result["backend"] == backend and result["languagePair"] == language_pair
                ]
            )
            for language_pair in sorted({result["languagePair"] for result in results if result["backend"] == backend})
        }
        for backend in sorted({result["backend"] for result in results})
    }

    slowest_cases = [
        {
            "backend": result["backend"],
            "id": result["id"],
            "languagePair": result["languagePair"],
            "latencyMs": result["latencyMs"],
            "checksPassed": result["checksPassed"],
        }
        for result in sorted(results, key=lambda value: value["latencyMs"], reverse=True)[:5]
    ]

    return {
        "overall": summarize_result_group(results),
        "backends": backends,
        "backendLanguagePairs": backend_language_pairs,
        "languagePairs": language_pairs,
        "terms": {
            "missingRequired": dict(missing_terms.most_common()),
            "forbiddenHits": dict(forbidden_hits.most_common()),
            "byBackend": {
                backend: {
                    "missingRequired": dict(
                        Counter(
                            term
                            for result in results
                            if result["backend"] == backend
                            for term in list(result["missingRequiredTerms"]) + list(result["missingRequiredTermGroups"])
                        ).most_common()
                    ),
                    "forbiddenHits": dict(
                        Counter(
                            term
                            for result in results
                            if result["backend"] == backend
                            for term in result["forbiddenTermHits"]
                        ).most_common()
                    ),
                }
                for backend in sorted({result["backend"] for result in results})
            },
        },
        "slowestCases": slowest_cases,
    }


def markdown_escape(text: Any) -> str:
    value = "" if text is None else str(text)
    return value.replace("|", "\\|").replace("\n", "<br>")


def checks_summary(result: Dict[str, Any]) -> str:
    checks = "pass" if result["checksPassed"] else "fail"
    missing = list(result["missingRequiredTerms"]) + list(result["missingRequiredTermGroups"])
    if missing:
        checks += f"; missing: {', '.join(missing)}"
    if result["forbiddenTermHits"]:
        checks += f"; forbidden: {', '.join(result['forbiddenTermHits'])}"
    if result["error"]:
        checks += f"; error: {result['error']}"
    return checks


def markdown_count_table(title: str, counts: Dict[str, int]) -> List[str]:
    lines = [f"## {title}", ""]
    if not counts:
        return lines + ["None.", ""]

    lines.extend(["| Term | Count |", "| --- | ---: |"])
    for term, count in counts.items():
        lines.append(f"| {markdown_escape(term)} | {count} |")
    lines.append("")
    return lines


def write_reports(report: Dict[str, Any], reports_dir: Path) -> None:
    reports_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    json_path = reports_dir / f"translation_eval_{stamp}.json"
    markdown_path = reports_dir / f"translation_eval_{stamp}.md"

    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# Translation Text Eval",
        "",
        f"- Started: `{report['startedAt']}`",
        f"- Python: `{report['runtime']['python']}`",
        f"- Backends: `{', '.join(report['selectedBackends'])}`",
        f"- Total: `{report['summary']['total']}`",
        f"- Passed: `{report['summary']['passed']}`",
        f"- Failed: `{report['summary']['failed']}`",
        f"- Average similarity: `{report['summary']['averageSimilarity']}`",
        f"- Average latency: `{report['summary']['averageLatencyMs']} ms`",
        "",
        "## Backend Summary",
        "",
        "| Backend | Total | Passed | Failed | Avg Similarity | Avg Latency |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]

    for backend, summary in report["backendSummaries"].items():
        lines.append(
            "| "
            + " | ".join(
                [
                    markdown_escape(backend),
                    markdown_escape(summary["total"]),
                    markdown_escape(summary["passed"]),
                    markdown_escape(summary["failed"]),
                    markdown_escape(summary["averageSimilarity"]),
                    markdown_escape(f"{summary['averageLatencyMs']} ms"),
                ]
            )
            + " |"
        )

    lines.extend(
        [
            "",
        "## Language Pair Summary",
        "",
            "| Backend | Pair | Total | Passed | Failed | Avg Similarity | Avg Latency |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for backend, pair_summaries in report["backendLanguagePairSummaries"].items():
        for language_pair, summary in pair_summaries.items():
            lines.append(
                "| "
                + " | ".join(
                    [
                        markdown_escape(backend),
                        markdown_escape(language_pair),
                        markdown_escape(summary["total"]),
                        markdown_escape(summary["passed"]),
                        markdown_escape(summary["failed"]),
                        markdown_escape(summary["averageSimilarity"]),
                        markdown_escape(f"{summary['averageLatencyMs']} ms"),
                    ]
                )
                + " |"
            )

    lines.extend(
        [
            "",
            "## Missing Required Terms By Backend",
            "",
            "| Backend | Term | Count |",
            "| --- | --- | ---: |",
        ]
    )
    has_missing_terms = False
    for backend, terms in report["termSummaries"]["byBackend"].items():
        for term, count in terms["missingRequired"].items():
            has_missing_terms = True
            lines.append(f"| {markdown_escape(backend)} | {markdown_escape(term)} | {count} |")
    if not has_missing_terms:
        lines.append("|  | None | 0 |")

    lines.extend(
        [
            "",
            "## Forbidden Term Hits By Backend",
            "",
            "| Backend | Term | Count |",
            "| --- | --- | ---: |",
        ]
    )
    has_forbidden_terms = False
    for backend, terms in report["termSummaries"]["byBackend"].items():
        for term, count in terms["forbiddenHits"].items():
            has_forbidden_terms = True
            lines.append(f"| {markdown_escape(backend)} | {markdown_escape(term)} | {count} |")
    if not has_forbidden_terms:
        lines.append("|  | None | 0 |")

    lines.extend(
        [
            "",
            "## Slowest Cases",
            "",
            "| Backend | ID | Pair | Latency | Checks |",
            "| --- | --- | --- | ---: | --- |",
        ]
    )

    for result in report["slowestCases"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    markdown_escape(result["backend"]),
                    markdown_escape(result["id"]),
                    markdown_escape(result["languagePair"]),
                    markdown_escape(f"{result['latencyMs']} ms"),
                    markdown_escape("pass" if result["checksPassed"] else "fail"),
                ]
            )
            + " |"
        )

    lines.extend(
        [
            "",
            "## Case Results",
            "",
            "| Backend | ID | Pair | Source | Reference | Output | Checks | Similarity | Latency | Review Decision | Review Notes |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )

    for result in report["results"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    markdown_escape(result["backend"]),
                    markdown_escape(result["id"]),
                    markdown_escape(result["languagePair"]),
                    markdown_escape(result["sourceText"]),
                    markdown_escape(result["referenceEnglish"]),
                    markdown_escape(result["translatedText"]),
                    markdown_escape(checks_summary(result)),
                    markdown_escape(result["similarity"]),
                    markdown_escape(f"{result['latencyMs']} ms"),
                    markdown_escape(result["reviewDecision"]),
                    markdown_escape(result["reviewNotes"]),
                ]
            )
            + " |"
        )

    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {json_path}")
    print(f"Wrote {markdown_path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local translation quality evals.")
    parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument("--reports-dir", type=Path, default=DEFAULT_REPORTS_DIR)
    parser.add_argument("--case", dest="case_id", help="Run one fixture by id.")
    parser.add_argument("--language-pair", choices=["th-en", "ja-en"], help="Run only one language pair.")
    parser.add_argument("--backend", choices=BACKEND_CHOICES, default=OPUS_BACKEND)
    parser.add_argument("--no-report", action="store_true", help="Run without writing JSON or Markdown reports.")
    parser.add_argument("--strict", action="store_true", help="Exit nonzero when automatic checks fail.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cases = filter_cases(load_cases(args.fixtures), args.case_id, args.language_pair)
    report = run_eval(cases, python_path(), args.backend)
    if not args.no_report:
        write_reports(report, args.reports_dir)
    failed = report["summary"]["failed"]
    if failed:
        if args.no_report:
            print(
                f"Eval completed with {failed} automatic check failure(s). "
                "Re-run without --no-report for a Markdown review report."
            )
        else:
            print(f"Eval completed with {failed} automatic check failure(s). Review the Markdown report.")
        if args.strict:
            return 1
    else:
        print("Eval completed with all automatic checks passing.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
