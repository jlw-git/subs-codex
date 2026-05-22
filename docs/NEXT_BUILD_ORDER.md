# Next Build Order

Last reviewed: 2026-05-22

This file is the canonical product context for what to build next. Update it
whenever product priorities change, and keep the short README summary in sync.

## Product Position

Subs is currently a runnable local-first macOS prototype, not an alpha-ready
product. The core promise is:

```text
Thai/Japanese meeting audio
  -> local system-audio capture
  -> local Whisper speech-to-text
  -> local OPUS-MT translation
  -> live English subtitles
```

The non-negotiable product invariant remains local-only processing. Do not add
cloud fallback for speech recognition, translation, summaries, diagnostics, or
transcript memory.

## Current Build State

Built now:

- Mac system-audio capture with ScreenCaptureKit.
- Local WhisperKit speech-to-text for Thai and Japanese.
- Local OPUS-MT Thai/Japanese -> English translation.
- Menu bar control surface.
- Floating subtitle window.
- In-memory bilingual transcript window.
- Basic local model/runtime setup and translation eval tooling.
- Local no-text reliability reports for trust-build sessions, with JSON and
  Markdown artifacts under the user's Application Support folder.
- A manual trust-build test plan covering Thai/Japanese cold and warm starts,
  silence/noisy audio, and local setup failure recovery.

Recent focus:

- Faster ASR startup through warm local Whisper reuse.
- Real audio RMS metering instead of synthetic activity.
- Overlapping Whisper decode windows.
- Quiet-chunk, low-confidence, and duplicate filtering.
- Candidate subtitle state and recognition debug metrics.
- Trust Build v0 instrumentation: first-audio timing, ASR/capture readiness,
  first candidate/accepted/translated subtitle timing, translation latency
  aggregation, failure stages, and Settings visibility for the latest report.

## Next Build Order

1. End-to-end call reliability sprint.

   Run the `docs/TRUST_BUILD_TEST_PLAN.md` matrix in real or realistic
   Teams/system-audio sessions before expanding product surface area. Use the
   generated local reliability reports to compare cold start, warm start, time
   to first accepted subtitle, candidate-to-accepted ratio, duplicate rate,
   skipped quiet chunks, translation latency, failure states, and crashes. Fix
   the highest-impact trust breakers found in those reports and manual notes.

2. Expanded translation eval.

   Grow the synthetic text eval beyond the current small fixture set before
   changing translation models. Cover meeting decisions, deadlines, risks,
   owners, dates, Teams/audio issues, and action items for both Thai and
   Japanese. Use failures to decide whether OPUS-MT remains acceptable or
   whether the M2M100 bakeoff should move toward runtime integration.

3. Setup/readiness checklist.

   Add a first-run or settings status surface that clearly shows whether Screen
   & System Audio permission, local Whisper model files, OPUS-MT runtime, Thai
   model, Japanese model, local-only mode, and latest reliability report status
   are ready before a meeting starts.

4. Subtitle overlay polish.

   Make the overlay feel like the daily product surface: always-on-top behavior,
   sensible window placement, readable compact layout, and a path toward
   click-through behavior where macOS allows it. Keep developer debug metrics
   out of the default user-facing overlay.

5. Defer transcript persistence and diarization.

   Persistent encrypted transcript storage and speaker diarization are valuable,
   but they should wait until live captions are fast, stable, and trustworthy in
   actual meetings.

## Current Product Gate

The next meaningful milestone remains a "trust build": a build that proves a
user can join a Thai or Japanese meeting, press Start, and receive useful local
subtitles without repeated hallucinations, confusing candidate text, silent setup
failures, or unacceptable latency. Trust Build v0 can now measure those risks;
the next product work is to run the matrix and fix the top failures.

Do not treat additional features as higher priority than this gate unless a
real user test changes the product evidence.
