# Local Translation Model Options

Subs uses a local translation backend for Thai/Japanese to English. The local
Whisper model only handles speech-to-text.

The translation stage is separate:

```text
Thai/Japanese audio
  -> Local Whisper ASR
  -> Thai/Japanese text
  -> local translation model
  -> English text
```

## Implemented first backend: OPUS-MT

Subs uses OPUS-MT first because it is small, specific to translation, and
easier to test locally than a large general LLM.

Candidate models:

- `Helsinki-NLP/opus-mt-th-en` for Thai -> English
- `Helsinki-NLP/opus-mt-ja-en` for Japanese -> English

Why these models:

- They are exact matches for the app's current product scope:
  Thai -> English and Japanese -> English, with no unused language surface in
  the first implementation.
- They are Marian/OPUS translation models exposed through Hugging Face
  Transformers, so the first backend can be a small local runner instead of a
  custom inference engine.
- They can be downloaded once, stored as local model folders, and loaded with
  `local_files_only`, which fits the no-cloud runtime contract.
- Their Hugging Face model cards list Apache-2.0 licensing, making them easier
  to evaluate for bundled/local distribution than many research-only or
  non-commercial alternatives.
- They are much lighter operationally than NLLB-style multilingual models,
  which matters for a menu bar app that should start quickly on ordinary Macs.
- The translation step receives already-transcribed text, so pair-specific MT is
  a better first risk reducer than a general LLM. We can evaluate quality per
  language pair and replace one pair without disturbing the other.

Japanese naming note:

- Use `Helsinki-NLP/opus-mt-ja-en` for this app, not
  `Helsinki-NLP/opus-mt-jap-en`, unless evaluation later proves otherwise.
  `ja-en` matches the app's `ja` language code and the model card identifies
  Japanese and English directly. `jap-en` also exists, but its model-card
  language tag is `jap`, and the visible benchmark is a Bible-domain test set,
  so it is not the cleaner default for meeting subtitles.

Known quality caveat:

- OPUS-MT is the best first local backend, not a final quality guarantee.
  Meeting speech is short, noisy, and ASR-shaped, so Thai and Japanese output
  must be evaluated with real meeting snippets before treating this as
  production quality.

## Translation quality eval

Run the local text-only eval with OPUS-MT, which remains the default backend:

```sh
./script/evaluate_translation.py
```

The eval uses synthetic, non-sensitive meeting-style cases in
`eval/fixtures/translation_text_cases.jsonl`. It talks to the same bundled
`opus_mt_translate.py --worker` process used by the app, honors the same runtime
and model environment overrides, and writes ignored Markdown/JSON reports under
`eval/reports/`.

Useful reviewer commands:

```sh
./script/evaluate_translation.py --case ja-risk-001
./script/evaluate_translation.py --language-pair th-en
./script/evaluate_translation.py --backend opus-mt
./script/evaluate_translation.py --no-report
./script/evaluate_translation.py --strict
```

Run the eval-only M2M100 418M bakeoff candidate with:

```sh
./script/setup_m2m100_bakeoff.sh
./script/evaluate_translation.py --backend m2m100-418m
./script/evaluate_translation.py --backend all
```

M2M100 is installed under:

```text
~/Library/Application Support/Subs/Models/translation-bakeoff/m2m100-418m
```

This bakeoff path does not change `LocalTranslationService` or the app runtime
backend. Eval worker requests time out after 180 seconds by default; override
with `SUBS_TRANSLATION_EVAL_TIMEOUT_SECONDS` when intentionally testing a slower
local candidate.

V1 scoring is deliberately lightweight:

- output must be non-empty
- required English terms should appear
- required term groups can define acceptable alternate phrasings
- forbidden English terms should not appear
- rough similarity is computed with Python's standard-library text matching
- latency is recorded per case

These checks are triage signals for human review, not formal BLEU/chrF scores.

## Eval-only model bakeoff

The current production-path translation backend remains OPUS-MT:

- `Helsinki-NLP/opus-mt-th-en`: Apache-2.0, exact Thai -> English pair
- `Helsinki-NLP/opus-mt-ja-en`: Apache-2.0, exact Japanese -> English pair

The first eval-only challenger is:

- `facebook/m2m100_418M`: MIT, multilingual, supports Thai, Japanese, and
  English in one model family

NLLB-200 is not included as a production candidate for now. The available
distilled 600M checkpoint is CC-BY-NC and its model card says it is not released
for production deployment.

Integration:

1. Install the models locally.
2. The app invokes the bundled `opus_mt_translate.py` runner as a persistent
   worker process.
3. The runner loads models through Python Transformers with `local_files_only`.
4. Capture startup warms only the selected language pair in the background so
   ASR and audio capture are not blocked by Python/model initialization.
5. The runner caches loaded models by language pair for repeated subtitle
   translations.
6. The runner is wrapped behind a `TranslationBackend` interface.
7. Later optimize with CTranslate2, Marian, Core ML, or another native bridge.

Default runtime:

```text
~/Library/Application Support/Subs/Runtime/opus/bin/python
```

Install or refresh the runtime and model folders with:

```sh
./script/setup_opus_mt.sh
```

Default model folders:

```text
~/Library/Application Support/Subs/Models/opus-mt/th-en
~/Library/Application Support/Subs/Models/opus-mt/ja-en
```

Development overrides:

- `SUBS_OPUS_MT_MODELS_DIR`: directory containing `th-en` and `ja-en`
- `SUBS_OPUS_MT_MODEL_TH_EN`: explicit Thai -> English model folder
- `SUBS_OPUS_MT_MODEL_JA_EN`: explicit Japanese -> English model folder
- `SUBS_PYTHON`: Python executable with local `transformers` installed

These overrides are for development and debugging. The GUI app defaults to the
App Support runtime so it can launch from Finder/menu bar without inheriting a
shell environment.

Worker protocol:

- Request:
  `{ "id": "...", "command": "translate", "sourceText": "...", "sourceLanguageCode": "th", "targetLanguageCode": "en", "modelPath": "..." }`
- Success:
  `{ "id": "...", "ok": true, "translatedText": "..." }`
- Failure:
  `{ "id": "...", "ok": false, "error": "..." }`

Setup smoke tests:

- Thai input `สวัสดี` should produce a non-empty English translation such as
  `Hello?`.
- Japanese input `こんにちは` should produce a non-empty English translation.
- `sacremoses` is installed by setup to avoid the Marian tokenizer warning.
- Python OpenSSL/LibreSSL warnings may appear during download on older Python
  builds, but runtime translation uses local files only.

Pros:

- focused translation models
- smaller than LLMs
- good first implementation path
- no Apple Translation dependency
- Apache-2.0 model-card license on the selected Hugging Face repos

Cons:

- likely needs a Python/local runtime bridge at first
- separate models per language pair
- quality must be evaluated for meeting speech
- not as broad as a multilingual model if the product expands beyond
  Thai/Japanese -> English

## Alternative: NLLB-200

NLLB-200 is a multilingual translation model that can support both Thai and
Japanese to English in one model family.

Pros:

- multilingual
- one model family can cover many future languages
- promising for product expansion

Cons:

- heavier than OPUS-MT
- more integration work
- needs careful runtime and memory testing
- broader language coverage than the current product needs

## Removed alternative: Apple Translation

Apple Translation can be useful on macOS 15+ when the language packs are
available, but Subs no longer depends on it for realtime translation.

Pros:

- native Apple framework
- on-device
- no separate model runtime to ship

Cons:

- requires macOS 15+
- not a solution for macOS 14
- less control over model packaging and enterprise deployment

## Local-only rule

Any translation backend must follow `docs/LOCAL_ONLY_ARCHITECTURE.md`.

If the translation model is missing, the app must show an error. It must not
send source text, transcripts, or translations to a cloud service.
