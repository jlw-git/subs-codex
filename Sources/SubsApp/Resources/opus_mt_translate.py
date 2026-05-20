#!/usr/bin/env python3
"""Run a local OPUS-MT translation worker without network access."""

import argparse
import json
import os
import sys
from typing import Any, Dict, Tuple


_MODEL_CACHE: Dict[Tuple[str, str, str], Tuple[Any, Any]] = {}


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
        import transformers  # noqa: F401
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer  # noqa: F401
    except ImportError as error:
        raise RuntimeError(
            "The local OPUS-MT runtime requires Python packages "
            "'transformers[torch]', 'sentencepiece', and 'sacremoses'. "
            f"Run script/setup_opus_mt.sh and retry. Import error: {error}"
        ) from error


def load_model(model_path: str, source_language_code: str, target_language_code: str) -> Tuple[Any, Any]:
    if not model_path or not os.path.isdir(model_path):
        raise RuntimeError(
            "Local OPUS-MT model folder was not found at "
            f"{model_path!r}. Install the model locally and retry; Subs did not "
            "download a model or use a cloud fallback."
        )

    cache_key = (model_path, source_language_code, target_language_code)
    if cache_key in _MODEL_CACHE:
        return _MODEL_CACHE[cache_key]

    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_path, local_files_only=True)
    model = AutoModelForSeq2SeqLM.from_pretrained(model_path, local_files_only=True)
    _MODEL_CACHE[cache_key] = (tokenizer, model)
    return tokenizer, model


def translate(request: Dict[str, Any]) -> str:
    source_text = request.get("sourceText", "")
    if not source_text.strip():
        return ""

    validate_runtime()
    tokenizer, model = load_model(
        request.get("modelPath", ""),
        request.get("sourceLanguageCode", ""),
        request.get("targetLanguageCode", ""),
    )
    inputs = tokenizer(source_text, return_tensors="pt", truncation=True)
    generated = model.generate(**inputs, max_new_tokens=256)
    return tokenizer.decode(generated[0], skip_special_tokens=True)


def handle_request(request: Dict[str, Any]) -> Dict[str, Any]:
    command = request.get("command", "translate")
    if command != "translate":
        raise RuntimeError(f"Unsupported OPUS-MT worker command: {command}")

    return {"translatedText": translate(request)}


def run_worker() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue

        request_id = ""
        try:
            request = json.loads(line)
            request_id = request.get("id", "")
            result = handle_request(request)
            print(response(request_id, True, translated_text=result["translatedText"]), flush=True)
        except Exception as error:
            print(response(request_id, False, error=str(error)), flush=True)


def run_single_request() -> None:
    try:
        request = json.load(sys.stdin)
        request_id = request.get("id", "")
        result = handle_request(request)
        print(json.dumps({"translatedText": result["translatedText"]}, ensure_ascii=False))
    except json.JSONDecodeError as error:
        print(f"Invalid translation request JSON: {error}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true", help="Read newline-delimited JSON requests from stdin.")
    args = parser.parse_args()

    if args.worker:
        run_worker()
    else:
        run_single_request()


if __name__ == "__main__":
    main()
