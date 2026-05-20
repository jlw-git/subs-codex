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
  `~/Library/Application Support/Subs/Models/whisperkit`. The app keeps the
  loaded Whisper backend warm across stop/start cycles while it remains open.
- **Translation**: local OPUS-MT runtime for Thai/Japanese -> English. It uses
  local model files only and does not use Apple Translation. Translation warmup
  runs after audio capture starts and preflights only the selected language pair.

The current ASR choices are:

- `Local Whisper`: primary product path for Thai/Japanese speech-to-text.
- `Apple Speech`: diagnostic/local fallback for languages and Macs where
  Apple's `supportsOnDeviceRecognition` is available.

The first local translation backend is deliberately narrow:

- OPUS-MT Thai -> English and Japanese -> English are the first local
  translation backends.
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
  -> local OPUS-MT translation backend for the selected pair
  -> live subtitle overlay
  -> local transcript memory
```

Startup is staged so ASR and audio capture are not blocked by the heavier
translation runtime. Whisper loads from local Core ML files, capture starts, and
then the OPUS-MT worker warms the selected translation model in the background.

No OpenAI API, cloud transcription API, cloud translation API, or network SDK is
used in the app.

## Local-only design

The local privacy story is enforced in code:

- Audio capture uses Apple's `ScreenCaptureKit`.
- Primary speech recognition uses local WhisperKit model files.
- WhisperKit is configured with `download: false` at runtime.
- Apple Speech, when selected, is configured with
  `requiresOnDeviceRecognition = true`.
- Local translation uses the bundled OPUS-MT runner script with locally
  installed model folders. Runtime warmup and translation load only the selected
  local language-pair folder.
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
- `Sources/SubsApp/Views/LiveSubtitlesView.swift`: main live subtitle panel.
- `Sources/SubsApp/Views/TranscriptMemoryView.swift`: bilingual transcript list.
- `Sources/SubsApp/Views/SidebarView.swift`: session status and language
  controls in the main window.
- `Sources/SubsApp/Views/SettingsView.swift`: privacy/runtime settings display.
- `script/build_and_run.sh`: builds, stages, and launches the macOS app bundle.
- `script/evaluate_translation.py`: runs local OPUS-MT text translation quality
  checks against synthetic fixtures.
- `script/setup_m2m100_bakeoff.sh`: installs the eval-only M2M100 418M
  translation candidate for local bakeoff runs.
- `.codex/environments/environment.toml`: gives Codex a Run action.
- `docs/LOCAL_ONLY_ARCHITECTURE.md`: non-negotiable no-cloud architecture
  policy for future backend changes.
- `docs/LOCAL_WHISPER_MODEL_SETUP.md`: where local WhisperKit model files must
  be installed for the `Local Whisper` backend.
- `docs/LOCAL_TRANSLATION_MODEL_OPTIONS.md`: local translation model options for
  Thai/Japanese -> English and why OPUS-MT is the first backend.

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
- Local Thai/Japanese -> English translation requires local OPUS-MT model
  folders and a local Python environment with `transformers` installed.
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

Local OPUS-MT model folders are discovered at:

```text
~/Library/Application Support/Subs/Models/opus-mt/th-en
~/Library/Application Support/Subs/Models/opus-mt/ja-en
```

Install the local OPUS-MT Python runtime and model assets:

```sh
./script/setup_opus_mt.sh
```

The setup script creates the default GUI runtime at:

```text
~/Library/Application Support/Subs/Runtime/opus/bin/python
```

For development, set `SUBS_OPUS_MT_MODELS_DIR` to a directory containing
`th-en` and `ja-en`, or set `SUBS_OPUS_MT_MODEL_TH_EN` /
`SUBS_OPUS_MT_MODEL_JA_EN` to explicit model folders. Set `SUBS_PYTHON` if the
Python environment with `transformers` should override the App Support runtime.
These environment variables are development overrides; the GUI app defaults to
the App Support runtime so it does not depend on a shell session.

The bundled OPUS-MT runner stays alive as a worker process while the app is
translating. It reads newline-delimited JSON requests, writes JSON responses,
and caches loaded models by language pair. Runtime translation loads model
files with `local_files_only=True`; network access is only part of the setup
script download step.

During capture startup, the app warms only the selected language pair in the
background. The first translation for a cold pair may still include local Python
and model-load time, but ASR and audio capture can already be running.

Expected setup smoke-test output is a non-empty English translation for both
Thai `สวัสดี` and Japanese `こんにちは`. The setup script installs `sacremoses`
to avoid Marian tokenizer warnings. If Python still prints an OpenSSL/LibreSSL
warning during setup downloads, it is a Python networking warning and not part
of app runtime translation.

Run the local translation quality eval. The default backend is still OPUS-MT:

```sh
./script/evaluate_translation.py
```

The eval uses synthetic meeting-style fixtures from
`eval/fixtures/translation_text_cases.jsonl`, drives the bundled OPUS-MT worker,
and writes ignored JSON/Markdown reports under `eval/reports/`. Automatic
checks cover non-empty output, required term coverage, acceptable required term
groups, forbidden term hits, rough standard-library text similarity, and
per-case latency. Reports include per-language summaries, term miss summaries,
slowest cases, backend summaries, and reviewer fields. Treat those scores as
triage for human review, not as a formal MT benchmark.

Useful eval filters:

```sh
./script/evaluate_translation.py --case ja-risk-001
./script/evaluate_translation.py --language-pair th-en
./script/evaluate_translation.py --backend opus-mt
./script/evaluate_translation.py --no-report
./script/evaluate_translation.py --strict
```

To run the eval-only M2M100 418M bakeoff candidate:

```sh
./script/setup_m2m100_bakeoff.sh
./script/evaluate_translation.py --backend m2m100-418m
./script/evaluate_translation.py --backend all
```

M2M100 files are stored at:

```text
~/Library/Application Support/Subs/Models/translation-bakeoff/m2m100-418m
```

This does not change the app runtime translation backend. Eval worker requests
time out after 180 seconds by default; override with
`SUBS_TRANSLATION_EVAL_TIMEOUT_SECONDS` if a slower local machine needs a longer
bakeoff run.

The selected model repos are:

- `Helsinki-NLP/opus-mt-th-en` for Thai -> English
- `Helsinki-NLP/opus-mt-ja-en` for Japanese -> English

These were chosen because they are exact language-pair translation models,
usable through the local Transformers API, Apache-2.0 licensed, small enough for
a first offline runtime, and easier to package/evaluate than a broad
multilingual model. `opus-mt-ja-en` is used instead of `opus-mt-jap-en` because
it matches the app's `ja` language code and the Hugging Face model card names
Japanese/English directly.

The eval-only bakeoff candidate is `facebook/m2m100_418M`, which is MIT
licensed and supports Thai, Japanese, and English in one model family. NLLB-200
is not a production candidate in this repo because the available distilled
checkpoint is CC-BY-NC and its model card says it is not released for production
deployment.

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
- `.venv-opus/`: optional development-only Python venv.
- `eval/reports/`: generated local translation eval reports.

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
  Local OPUS-MT Thai/Japanese -> English translation
  Menu bar control
  Subtitle window
  Transcript memory

Still next:
  Persistent encrypted transcript storage
  Better subtitle overlay behavior
```

Apple Translation is no longer part of the realtime translation path. The
current backend expects locally installed OPUS-MT model folders and a local
Python runtime.
