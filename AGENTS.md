# Agent Context

This repo is a SwiftPM macOS app for local-first realtime meeting subtitles and
translation. The product promise is local-only Thai/Japanese meeting audio to
English subtitles. Meeting audio, transcripts, translations, diagnostics, and
memory must not be sent to cloud services.

Read these context files before changing product direction:

- `docs/LOCAL_ONLY_ARCHITECTURE.md`: non-negotiable privacy and backend policy.
- `docs/NEXT_BUILD_ORDER.md`: canonical next-build priority order.
- `docs/LOCAL_TRANSLATION_MODEL_OPTIONS.md`: local translation model choices and
  eval approach.
- `docs/LOCAL_WHISPER_MODEL_SETUP.md`: local WhisperKit model setup.

Current next-build order:

1. End-to-end call reliability sprint.
2. Expanded translation eval.
3. Setup/readiness checklist.
4. Subtitle overlay polish.
5. Defer transcript persistence and diarization until live subtitles are
   trustworthy in real meetings.

Use `./script/build_and_run.sh --verify` to build, stage, sign, launch, and
confirm the app process is running.
