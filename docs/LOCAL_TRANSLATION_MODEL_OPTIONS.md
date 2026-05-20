# Local Translation Model Options

Subs still needs a local translation backend for Thai/Japanese to English on
macOS 14. The local Whisper model only handles speech-to-text.

The translation stage is separate:

```text
Thai/Japanese audio
  -> Local Whisper ASR
  -> Thai/Japanese text
  -> local translation model
  -> English text
```

## Recommended first prototype: OPUS-MT

Use OPUS-MT first because it is small, specific to translation, and easier to
test locally than a large general LLM.

Candidate models:

- `Helsinki-NLP/opus-mt-th-en` for Thai -> English
- `Helsinki-NLP/opus-mt-ja-en` for Japanese -> English

Expected integration path:

1. Install the models locally.
2. Run them through a local runtime such as Python Transformers first.
3. Wrap that local runtime behind a `TranslationBackend` interface.
4. Later optimize with CTranslate2, Marian, Core ML, or another native bridge.

Pros:

- focused translation models
- smaller than LLMs
- good first implementation path
- no Apple Translation dependency

Cons:

- likely needs a Python/local runtime bridge at first
- separate models per language pair
- quality must be evaluated for meeting speech

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

## Alternative: Apple Translation

Apple Translation can be useful on macOS 15+ when the language packs are
available.

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
