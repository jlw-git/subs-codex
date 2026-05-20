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

The current code uses Apple's built-in local frameworks first:

- Apple Speech for on-device speech recognition
- Apple Translation for on-device translation

This is useful for proving the local-first app architecture, but it has two
important product constraints:

- Thai speech recognition is not supported by the current Apple Speech backend
  on the test Mac.
- Apple Translation requires macOS 15 or later.

For production Thai/Japanese support across more Macs, the next backend should
be a bundled local model stack:

- WhisperKit, whisper.cpp, or another local Whisper-style ASR runtime for
  Thai/Japanese speech-to-text
- a bundled local translation model for Thai/Japanese to English

The app intentionally does not fall back to cloud recognition or translation.

The app now has an explicit ASR backend selector:

- `Local Whisper`: the intended production ASR path; currently a fail-closed
  placeholder until a local Whisper runtime and model are bundled.
- `Apple Speech`: local-only Apple Speech backend for languages/macOS versions
  where `supportsOnDeviceRecognition` is available.

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
  -> Apple Speech on-device speech recognition
  -> Apple Translation on-device translation
  -> live subtitle overlay
  -> local transcript memory
```

No OpenAI API, cloud transcription API, cloud translation API, or network SDK is
used in the app.

## Local-only design

The local privacy story is enforced in code:

- Audio capture uses Apple's `ScreenCaptureKit`.
- Speech recognition uses Apple's `Speech` framework.
- Speech recognition is configured with `requiresOnDeviceRecognition = true`.
- Translation uses Apple's `TranslationSession`.
- The app does not include any cloud API client.
- Transcript memory is currently in app memory only.

If on-device speech recognition is unavailable for a selected language, the app
shows an error instead of silently falling back to cloud recognition.

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
  speech recognition orchestration and backend selection.
- `Sources/SubsApp/Models/SpeechRecognitionBackendKind.swift`: available ASR
  backend choices.
- `Sources/SubsApp/Models/TranscriptModels.swift`: transcript and translation
  data models.
- `Sources/SubsApp/Views/MenuBarControlsView.swift`: menu bar controls.
- `Sources/SubsApp/Views/SubtitleOverlayView.swift`: floating live subtitle UI.
- `Sources/SubsApp/Views/LiveSubtitlesView.swift`: main live subtitle panel and
  Apple Translation task host.
- `Sources/SubsApp/Views/TranscriptMemoryView.swift`: bilingual transcript list.
- `Sources/SubsApp/Views/SidebarView.swift`: session status and language
  controls in the main window.
- `Sources/SubsApp/Views/SettingsView.swift`: privacy/runtime settings display.
- `script/build_and_run.sh`: builds, stages, and launches the macOS app bundle.
- `.codex/environments/environment.toml`: gives Codex a Run action.
- `docs/LOCAL_ONLY_ARCHITECTURE.md`: non-negotiable no-cloud architecture
  policy for future backend changes.

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

- Thai ASR currently requires replacing the Apple Speech backend with a local
  Whisper-style ASR model.
- Translation through Apple's Translation framework requires macOS 15 or later.
- The app still builds and runs on macOS 14, but translation is only enabled on
  macOS 15+.
- Availability of on-device speech recognition depends on macOS language support
  and installed language assets.
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

> The app chooses local-only Apple frameworks and refuses cloud fallback for
> speech recognition.
