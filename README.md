# Subs

Subs is a local-first macOS prototype for realtime meeting subtitles and translation.

The current build contains:

- local macOS system-audio capture through ScreenCaptureKit
- real on-device Thai/Japanese speech-to-text through Apple's Speech framework
- on-device Thai/Japanese to English translation through Apple's Translation framework
- local bilingual transcript memory
- no network SDKs or cloud calls

## Local-only guarantees

Speech recognition is configured with `requiresOnDeviceRecognition = true`.
Translation uses Apple's `TranslationSession`, which processes translation on the device.
The app has no cloud API clients.

## Run

```sh
./script/build_and_run.sh
```

On first capture, macOS may ask for Screen & System Audio Recording permission.
