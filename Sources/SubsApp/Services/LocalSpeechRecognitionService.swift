import AVFoundation
import Foundation
import Speech

@MainActor
final class LocalSpeechRecognitionService: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestTranscript = "Waiting for local audio..."
    @Published private(set) var activeBackendName = SpeechRecognitionBackendKind.localWhisper.title

    private var activeBackend: SpeechRecognitionBackend?

    func start(
        language: String,
        backendKind: SpeechRecognitionBackendKind,
        onRecognition: @escaping (String, Bool) -> Void
    ) async {
        stop()
        state = .requestingPermission

        let backend = Self.makeBackend(kind: backendKind)
        activeBackend = backend
        activeBackendName = backend.displayName

        do {
            try LocalOnlyPolicy.validate(backend.declaration)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        await backend.start(
            language: language,
            onRecognition: { [weak self] text, isFinal in
                self?.latestTranscript = text
                onRecognition(text, isFinal)
            },
            onStateChange: { [weak self] state in
                self?.state = state
            }
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        activeBackend?.append(buffer)
    }

    func stop() {
        activeBackend?.stop()
        activeBackend = nil
        latestTranscript = "Waiting for local audio..."
        state = .idle
    }

    private static func makeBackend(kind: SpeechRecognitionBackendKind) -> SpeechRecognitionBackend {
        switch kind {
        case .localWhisper: LocalWhisperSpeechRecognitionBackend()
        case .appleSpeech: AppleSpeechRecognitionBackend()
        }
    }
}

@MainActor
private protocol SpeechRecognitionBackend {
    var displayName: String { get }
    var declaration: LocalOnlyBackendDeclaration { get }

    func start(
        language: String,
        onRecognition: @escaping (String, Bool) -> Void,
        onStateChange: @escaping (CaptureState) -> Void
    ) async
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

@MainActor
private final class LocalWhisperSpeechRecognitionBackend: SpeechRecognitionBackend {
    let displayName = "Local Whisper"
    let declaration = LocalOnlyBackendDeclaration(
        name: "Local Whisper ASR",
        purpose: "speech-to-text",
        location: .onDevice,
        allowsCloudFallback: false
    )

    func start(
        language: String,
        onRecognition: @escaping (String, Bool) -> Void,
        onStateChange: @escaping (CaptureState) -> Void
    ) async {
        onStateChange(.failed("Local Whisper ASR is selected for \(language), but no local Whisper model/runtime is installed yet. Subs stopped here instead of using a cloud fallback."))
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func stop() {}
}

@MainActor
private final class AppleSpeechRecognitionBackend: NSObject, SpeechRecognitionBackend {
    let displayName = "Apple Speech"
    let declaration = LocalOnlyBackendDeclaration(
        name: "Apple Speech on-device recognition",
        purpose: "speech-to-text",
        location: .onDevice,
        allowsCloudFallback: false
    )

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(
        language: String,
        onRecognition: @escaping (String, Bool) -> Void,
        onStateChange: @escaping (CaptureState) -> Void
    ) async {
        onStateChange(.requestingPermission)

        let authorizationStatus = await requestAuthorization()
        guard authorizationStatus == .authorized else {
            onStateChange(.failed("Speech Recognition permission is required for local transcription."))
            return
        }

        let locale = Locale(identifier: Self.localeIdentifier(for: language))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            onStateChange(.failed("Speech recognition is not available for \(language)."))
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            onStateChange(.failed("On-device speech recognition is not installed or supported for \(language) in the Apple Speech backend. Subs did not fall back to cloud recognition."))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        self.recognizer = recognizer
        self.request = request
        onStateChange(.running)

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    onRecognition(text, result.isFinal)
                }

                if let error {
                    onStateChange(.failed("Local speech recognition stopped: \(error.localizedDescription)"))
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
