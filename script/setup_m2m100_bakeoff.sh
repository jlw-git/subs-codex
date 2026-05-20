#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Subs"
RUNTIME_DIR="$APP_SUPPORT/Runtime/opus"
BAKEOFF_DIR="$APP_SUPPORT/Models/translation-bakeoff"
M2M100_DIR="$BAKEOFF_DIR/m2m100-418m"
PYTHON_BIN="$RUNTIME_DIR/bin/python"

mkdir -p "$APP_SUPPORT/Runtime" "$BAKEOFF_DIR"

if [[ ! -x "$PYTHON_BIN" ]]; then
  python3 -m venv "$RUNTIME_DIR"
fi

"$PYTHON_BIN" -m pip install --upgrade pip
"$PYTHON_BIN" -m pip install "transformers[torch]" sentencepiece huggingface_hub

"$PYTHON_BIN" - <<PY
from huggingface_hub import snapshot_download
from pathlib import Path

model_dir = Path("${M2M100_DIR}")
model_dir.mkdir(parents=True, exist_ok=True)

snapshot_download(
    repo_id="facebook/m2m100_418M",
    local_dir=model_dir,
)
PY

"$PYTHON_BIN" - <<PY
from pathlib import Path
from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

model_dir = Path("${M2M100_DIR}")
tokenizer = M2M100Tokenizer.from_pretrained(model_dir, local_files_only=True)
model = M2M100ForConditionalGeneration.from_pretrained(model_dir, local_files_only=True)

for source_language, text in [("th", "สวัสดี"), ("ja", "こんにちは")]:
    tokenizer.src_lang = source_language
    inputs = tokenizer(text, return_tensors="pt", truncation=True)
    generated = model.generate(
        **inputs,
        forced_bos_token_id=tokenizer.get_lang_id("en"),
        max_new_tokens=64,
    )
    print(f"{source_language}-en smoke test: {tokenizer.batch_decode(generated, skip_special_tokens=True)[0]}")
PY

echo "M2M100 bakeoff runtime: $PYTHON_BIN"
echo "M2M100 bakeoff model: $M2M100_DIR"
echo "Run: $ROOT_DIR/script/evaluate_translation.py --backend m2m100-418m --case ja-risk-001"
