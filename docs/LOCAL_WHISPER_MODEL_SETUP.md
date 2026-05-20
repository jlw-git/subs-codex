# Local Whisper Model Setup

Subs can run the `Local Whisper` ASR backend only when WhisperKit Core ML model
files are installed locally.

The app looks for model files here:

```text
~/Library/Application Support/Subs/Models/whisperkit
```

Runtime transcription is configured with:

```swift
download: false
```

That means Subs does not download models while processing meeting audio and does
not fall back to a cloud speech service.

## Current development machine

The development machine currently has a small WhisperKit model installed at the
expected path. This makes the ASR stage ready to test locally.

This model handles speech-to-text only. It does not translate Thai/Japanese text
to English.

## Expected folder contents

The folder should contain a WhisperKit Core ML model package, including files
for:

- `MelSpectrogram`
- `AudioEncoder`
- `TextDecoder`
- tokenizer assets

The model files can come from Argmax's WhisperKit Core ML model repo or from an
internally distributed enterprise model bundle.

## Recommended development model

For local development, start with a small multilingual model so the feedback
loop is fast. For production Thai/Japanese quality, test larger multilingual
models before deciding what to bundle.

Argmax recommends `tiny` for fast debugging and larger multilingual models for
accuracy.

## Privacy rule

Downloading model files is different from sending meeting data to a cloud
service. However, enterprise builds should ideally bundle or preinstall model
files so runtime transcription works fully offline.

Meeting audio, transcripts, and translations must never leave the device.
