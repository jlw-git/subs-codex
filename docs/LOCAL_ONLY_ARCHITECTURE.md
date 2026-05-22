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
- WhisperKit with local model files
- whisper.cpp with local model files
- bundled Core ML models
- bundled local translation models
- OPUS-MT models running in a local runtime
- NLLB models running in a local runtime
- local SQLite or file storage
- local reliability reports that contain only timings, counters, backend names,
  and local error messages

## Disallowed architecture

Do not add:

- cloud transcription APIs
- cloud translation APIs
- cloud LLM summary APIs
- remote embeddings APIs
- remote logging of transcript/audio snippets
- local or remote diagnostic reports that include meeting audio, source text,
  translated text, transcript memory, or meeting-derived content
- silent network fallback when a local model is unavailable

If a local model is missing or unsupported, the app must show a local
availability error and stop that part of the pipeline.

Setup scripts may download local model files and local runtime dependencies.
Runtime translation must not download models or send meeting data to a network
service.

Startup may stage local components independently. ASR and audio capture should be
allowed to start once their local requirements pass; slower downstream local
translation warmup can run in the background as long as failures are surfaced
locally and no cloud fallback is introduced.

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

## Diagnostics and reliability reports

Local diagnostics are allowed only when they preserve the same privacy boundary
as the realtime pipeline. Reliability reports may record:

- timestamps and elapsed timings
- selected local backend names
- source and target language labels
- recognition counters such as candidate, accepted, duplicate, quiet-skip, and
  low-confidence counts
- translation attempt, success, failure, and latency counts
- local setup or runtime error messages

Reliability reports must not record:

- raw audio or processed audio features
- partial or final transcript text
- source-language text
- translated text
- speaker labels derived from meeting content
- meeting summaries, action items, decisions, or other meeting-derived metadata

Generated reliability reports should stay on the user's Mac, under local app
support storage, unless the user explicitly chooses to share a redacted report.

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

## Translation model selection rules

Prefer local translation models that:

- match the exact supported language pairs before adding broader multilingual
  coverage
- can be downloaded, pinned, and loaded from local files only
- expose a license that is compatible with local/bundled distribution review
- have a small enough runtime footprint for a menu bar app
- can be swapped behind the `TranslationBackend` interface without changing the
  rest of the capture/subtitle pipeline

The current first-choice models are `Helsinki-NLP/opus-mt-th-en` and
`Helsinki-NLP/opus-mt-ja-en`. NLLB-style multilingual models remain candidates
for broader language coverage, but they should not replace OPUS-MT unless local
latency, memory, package size, and meeting-domain quality are better in
evaluation.
