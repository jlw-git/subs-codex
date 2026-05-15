import AVFoundation
import Foundation
import Speech

@MainActor
final class LocalSpeechRecognitionService: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestTranscript = "Waiting for local audio..."

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(language: String, onRecognition: @escaping (String, Bool) -> Void) async {
        stop()
        state = .requestingPermission

        guard language != "Thai" else {
            state = .failed("Thai is not supported by the current Apple Speech backend on this Mac. To keep Thai fully local, Subs needs a local Whisper-style ASR model backend next. No cloud fallback was used.")
            return
        }

        let authorizationStatus = await requestAuthorization()
        guard authorizationStatus == .authorized else {
            state = .failed("Speech Recognition permission is required for local transcription.")
            return
        }

        let locale = Locale(identifier: Self.localeIdentifier(for: language))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            state = .failed("Speech recognition is not available for \(language).")
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            state = .failed("On-device speech recognition is not installed or supported for \(language) in the current Apple Speech backend. Subs did not fall back to cloud recognition.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        self.recognizer = recognizer
        self.request = request
        state = .running
        latestTranscript = "Listening locally..."

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.latestTranscript = text
                    onRecognition(text, result.isFinal)
                }

                if let error {
                    self.state = .failed("Local speech recognition stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        recognizer = nil
        latestTranscript = "Waiting for local audio..."
        state = .idle
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func localeIdentifier(for language: String) -> String {
        switch language {
        case "Japanese": "ja-JP"
        case "Thai": "th-TH"
        default: "en-US"
        }
    }
}
