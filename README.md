# Subs

Subs is a local-first macOS prototype for realtime meeting subtitles and
translation. It is designed for people who want meeting help without sending
meeting audio, transcripts, or translations to a cloud API.

The current product focus is:

- Thai to English subtitles
- Japanese to English subtitles
- local Teams/system-audio capture
- a menu bar control surface
- a floating subtitle window
- a local bilingual transcript window

## Current backend status

The current code is moving toward a fully bundled local model stack:

- **ASR / speech-to-text**: Local WhisperKit backend is wired and a local model
  has been installed on the development machine at
  `~/Library/Application Support/Subs/Models/whisperkit`.
- **Translation**: still needs a local translation backend for macOS 14. Apple
  Translation remains available only on macOS 15+.

The current ASR choices are:

- `Local Whisper`: primary product path for Thai/Japanese speech-to-text.
- `Apple Speech`: diagnostic/local fallback for languages and Macs where
  Apple's `supportsOnDeviceRecognition` is available.

The next major backend is local translation:

- OPUS-MT Thai -> English and Japanese -> English are good first candidates.
- NLLB-200 is a stronger multilingual candidate, but integration is heavier.

The app intentionally does not fall back to cloud recognition or translation.

## What the app does

Subs sits in the macOS menu bar. During a meeting, the user starts local capture
from the menu bar. The app captures system audio from the Mac, turns speech into
text on device, translates that text to English on device, and shows the result
in a lightweight subtitle overlay.

The user can also open a larger transcript window to review the bilingual
transcript lines.

## How it works

The core pipeline is:

```text
Teams/system audio
  -> ScreenCaptureKit local audio capture
  -> Local WhisperKit ASR
  -> local translation backend (next)
  -> live subtitle overlay
  -> local transcript memory
```

No OpenAI API, cloud transcription API, cloud translation API, or network SDK is
used in the app.

## Local-only design

The local privacy story is enforced in code:

- Audio capture uses Apple's `ScreenCaptureKit`.
- Primary speech recognition uses local WhisperKit model files.
- WhisperKit is configured with `download: false` at runtime.
- Apple Speech, when selected, is configured with
  `requiresOnDeviceRecognition = true`.
- Apple Translation, when available on macOS 15+, uses `TranslationSession`.
- The app does not include any cloud API client.
- Transcript memory is currently in app memory only.

If a local model/runtime is unavailable for a selected feature, the app shows an
error instead of silently falling back to cloud processing.

The full local-only architecture policy lives in
`docs/LOCAL_ONLY_ARCHITECTURE.md`. Any future ASR, translation, summary, memory,
or diagnostics backend must follow that policy.

## App surfaces

Subs has three main surfaces:

- **Menu bar app**: start/stop capture, choose source language, open subtitles,
  open transcript, open settings, quit.
- **Subtitle overlay**: lightweight window for live source text and English
  translation during a call.
- **Transcript window**: larger view that shows bilingual transcript lines with
  timestamps.

The menu bar is the daily control surface. The windows are there when the user
needs more space.

## Source tour

The app is a SwiftPM macOS app.

- `Package.swift`: Swift package definition and macOS deployment target.
- `Sources/SubsApp/App/SubsApp.swift`: app entry point, window scenes, menu bar
  scene, settings scene.
- `Sources/SubsApp/Stores/MeetingSessionStore.swift`: central session state and
  orchestration for capture, speech, translation, and transcript memory.
- `Sources/SubsApp/Services/SystemAudioCaptureService.swift`: local system-audio
  capture using `ScreenCaptureKit`.
- `Sources/SubsApp/Services/LocalSpeechRecognitionService.swift`: on-device
  speech recognition orchestration, backend selection, Apple Speech backend, and
  local WhisperKit backend.
- `Sources/SubsApp/Models/SpeechRecognitionBackendKind.swift`: available ASR
  backend choices.
- `Sources/SubsApp/Models/TranscriptModels.swift`: transcript and translation
  data models.
- `Sources/SubsApp/Views/MenuBarControlsView.swift`: menu bar controls.
- `Sources/SubsApp/Views/SubtitleOverlayView.swift`: floating live subtitle UI.
- `Sources/SubsApp/Views/LiveSubtitlesView.swift`: main live subtitle panel and
  translation task host.
- `Sources/SubsApp/Views/TranscriptMemoryView.swift`: bilingual transcript list.
- `Sources/SubsApp/Views/SidebarView.swift`: session status and language
  controls in the main window.
- `Sources/SubsApp/Views/SettingsView.swift`: privacy/runtime settings display.
- `script/build_and_run.sh`: builds, stages, and launches the macOS app bundle.
- `.codex/environments/environment.toml`: gives Codex a Run action.
- `docs/LOCAL_ONLY_ARCHITECTURE.md`: non-negotiable no-cloud architecture
  policy for future backend changes.
- `docs/LOCAL_WHISPER_MODEL_SETUP.md`: where local WhisperKit model files must
  be installed for the `Local Whisper` backend.
- `docs/LOCAL_TRANSLATION_MODEL_OPTIONS.md`: local translation model options for
  Thai/Japanese -> English on macOS 14.

## Current language support

The UI is intentionally narrowed to:

- Thai -> English
- Japanese -> English

Speech locales:

- Thai: `th-TH`
- Japanese: `ja-JP`

Translation locales:

- Thai: `th`
- Japanese: `ja`
- English: `en`

## Important limitations

This is still a prototype.

- Thai/Japanese ASR uses Local Whisper, but the current installed model is a
  small development model. Production quality needs model evaluation.
- Local Thai/Japanese -> English translation is not implemented yet.
- Translation through Apple's Translation framework requires macOS 15 or later.
- The app still builds and runs on macOS 14, but Apple Translation is only
  enabled on macOS 15+.
- Transcript memory is in memory only and is not persisted to disk yet.
- The subtitle overlay is a normal utility window today. It is not yet a
  polished always-on-top, click-through caption bar.
- Speaker diarization is not implemented yet, so all speech is labeled as
  meeting audio.

## Run locally

Build and launch:

```sh
./script/build_and_run.sh
```

Verify that the app launches:

```sh
./script/build_and_run.sh --verify
```

On first capture, macOS may ask for Screen & System Audio Recording permission
and Speech Recognition permission.

## Housekeeping

The source tree is intentionally small:

- `Sources/` contains the app code.
- `docs/` contains architecture notes.
- `script/` contains the build/run helper.
- `.codex/` contains the Codex Run action.

Generated folders are ignored by git:

- `.build/`: SwiftPM dependencies, build products, and local checkouts.
- `dist/`: staged `.app` bundle created by `script/build_and_run.sh`.

Both folders can be deleted and regenerated. Deleting `.build/` saves space but
means the next build will re-fetch and recompile dependencies.

## How to explain it

A simple way to describe the product:

> Subs is a macOS menu bar app that listens to meeting audio locally, transcribes
> Thai or Japanese speech on the Mac, translates it to English on the Mac, and
> shows live subtitles without sending meeting data to a cloud service.

The key technical idea:

> Instead of joining Teams as a bot, Subs captures the audio already playing on
> the user's Mac. That makes it lightweight and app-agnostic, while keeping the
> processing local.

The key privacy idea:

> The app uses local model files and local-only Apple frameworks, and refuses
> cloud fallback for speech recognition or translation.

## How to explain the backend state

The easiest way to explain the current build:

```text
Built now:
  Mac system audio capture
  Local Whisper speech-to-text
  Menu bar control
  Subtitle window
  Transcript memory

Still next:
  Local Thai/Japanese -> English translation model
  Persistent encrypted transcript storage
  Better subtitle overlay behavior
```

Apple Translation is not the long-term requirement. It is one possible local
translation backend on macOS 15+. For macOS 14 and enterprise offline installs,
the product should use a bundled local translation model instead.
