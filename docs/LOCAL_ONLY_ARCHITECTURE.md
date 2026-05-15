# Local-Only Architecture Policy

Subs has one non-negotiable product invariant:

> Realtime translation must stay on the user's device. Meeting audio,
> transcripts, translations, and transcript memory must not be sent to cloud
> services.

This policy applies even if the app architecture changes.

## What counts as meeting data

Meeting data includes:

- raw audio
- processed audio features
- partial transcripts
- final transcripts
- source-language text
- translated text
- transcript memory
- speaker labels
- meeting metadata derived from the conversation

None of this data may be sent to a remote API for speech recognition,
translation, summarization, analytics, debugging, telemetry, or logging.

## Allowed architecture

The allowed pipeline is:

```text
local audio capture
  -> local ASR model
  -> local translation model
  -> local subtitle UI
  -> local transcript memory
```

Allowed backend examples:

- Apple Speech only when `requiresOnDeviceRecognition = true`
- Apple Translation / `TranslationSession`
- WhisperKit with local model files
- whisper.cpp with local model files
- bundled Core ML models
- bundled local translation models
- local SQLite or file storage

## Disallowed architecture

Do not add:

- cloud transcription APIs
- cloud translation APIs
- cloud LLM summary APIs
- remote embeddings APIs
- remote logging of transcript/audio snippets
- silent network fallback when a local model is unavailable

If a local model is missing or unsupported, the app must show a local
availability error and stop that part of the pipeline.

## Backend contract

Every ASR, translation, summarization, memory, and diagnostics backend must be
able to answer:

- What data does it receive?
- Where is that data processed?
- Can it fall back to cloud processing?
- Where are outputs stored?

In code, backend services should declare a `LocalOnlyBackendDeclaration` and
pass `LocalOnlyPolicy.validate(...)` before they begin processing meeting data.

## Product behavior

When local processing is unavailable:

- show a clear error
- explain which local model/runtime is missing
- do not send data elsewhere
- do not ask the user to enable a cloud fallback

The privacy promise is more important than producing a transcript at all costs.

## Future architecture note

For Thai/Japanese to English across more Macs, the likely production path is:

```text
ScreenCaptureKit
  -> local Whisper-style ASR
  -> local Thai/Japanese-to-English translation model
  -> subtitle overlay
  -> encrypted local transcript store
```

That architecture is acceptable only if the ASR and translation models run
locally and model setup does not upload meeting data.
