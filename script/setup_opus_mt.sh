#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Subs"
RUNTIME_DIR="$APP_SUPPORT/Runtime/opus"
MODELS_DIR="$APP_SUPPORT/Models/opus-mt"
TH_MODEL_DIR="$MODELS_DIR/th-en"
JA_MODEL_DIR="$MODELS_DIR/ja-en"
PYTHON_BIN="$RUNTIME_DIR/bin/python"
RUNNER="$ROOT_DIR/Sources/SubsApp/Resources/opus_mt_translate.py"

mkdir -p "$APP_SUPPORT/Runtime" "$MODELS_DIR"

if [[ ! -x "$PYTHON_BIN" ]]; then
  python3 -m venv "$RUNTIME_DIR"
fi

"$PYTHON_BIN" -m pip install --upgrade pip
"$PYTHON_BIN" -m pip install "transformers[torch]" sentencepiece sacremoses huggingface_hub

"$PYTHON_BIN" - <<PY
from huggingface_hub import snapshot_download
from pathlib import Path

models_dir = Path("${MODELS_DIR}")
models_dir.mkdir(parents=True, exist_ok=True)

snapshot_download(
    repo_id="Helsinki-NLP/opus-mt-th-en",
    local_dir=models_dir / "th-en",
)
snapshot_download(
    repo_id="Helsinki-NLP/opus-mt-ja-en",
    local_dir=models_dir / "ja-en",
)
PY

thai_output="$(printf '{"sourceText":"สวัสดี","sourceLanguageCode":"th","targetLanguageCode":"en","modelPath":"%s"}' "$TH_MODEL_DIR" | "$PYTHON_BIN" "$RUNNER")"
japanese_output="$(printf '{"sourceText":"こんにちは","sourceLanguageCode":"ja","targetLanguageCode":"en","modelPath":"%s"}' "$JA_MODEL_DIR" | "$PYTHON_BIN" "$RUNNER")"

echo "Thai smoke test: $thai_output"
echo "Japanese smoke test: $japanese_output"
echo "OPUS-MT runtime: $PYTHON_BIN"
echo "OPUS-MT models: $MODELS_DIR"
