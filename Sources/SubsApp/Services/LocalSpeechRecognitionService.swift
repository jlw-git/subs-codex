import AVFoundation
import Foundation
import Speech
import WhisperKit

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

    private let chunkSampleCount = WhisperKit.sampleRate * 5
    private var whisperKit: WhisperKit?
    private var samples: [Float] = []
    private var isTranscribing = false
    private var languageCode = "th"
    private var onRecognition: ((String, Bool) -> Void)?
    private var onStateChange: ((CaptureState) -> Void)?

    func start(
        language: String,
        onRecognition: @escaping (String, Bool) -> Void,
        onStateChange: @escaping (CaptureState) -> Void
    ) async {
        self.onRecognition = onRecognition
        self.onStateChange = onStateChange
        languageCode = Self.languageCode(for: language)
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false

        guard let modelFolder = Self.localModelFolder(), FileManager.default.fileExists(atPath: modelFolder) else {
            onStateChange(.failed("""
            Local Whisper ASR is selected for \(language), but no local Whisper model folder was found. Install a WhisperKit Core ML model at ~/Library/Application Support/Subs/Models/whisperkit and retry. Subs stopped here instead of using a cloud fallback.
            """))
            return
        }

        do {
            let config = WhisperKitConfig(
                modelFolder: modelFolder,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            onStateChange(.running)
        } catch {
            onStateChange(.failed("Local Whisper ASR could not load the local model folder: \(error.localizedDescription). Subs did not use a cloud fallback."))
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard whisperKit != nil, let convertedSamples = Self.convertToWhisperSamples(buffer) else { return }
        samples.append(contentsOf: convertedSamples)

        guard samples.count >= chunkSampleCount, !isTranscribing else { return }
        let chunk = samples
        samples.removeAll(keepingCapacity: true)
        isTranscribing = true

        Task { @MainActor [weak self] in
            await self?.transcribe(chunk)
        }
    }

    func stop() {
        whisperKit = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        onRecognition = nil
        onStateChange = nil
    }

    private func transcribe(_ audioSamples: [Float]) async {
        defer { isTranscribing = false }

        guard let whisperKit else { return }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: languageCode,
                temperature: 0,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false
            )
            let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)
            let transcript = TranscriptionUtilities.mergeTranscriptionResults(results).text
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcript.isEmpty else { return }
            onRecognition?(transcript, true)
        } catch {
            onStateChange?(.failed("Local Whisper ASR failed while transcribing locally: \(error.localizedDescription). Subs did not use a cloud fallback."))
        }
    }

    private static func localModelFolder() -> String? {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return applicationSupport
            .appendingPathComponent("Subs", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("whisperkit", isDirectory: true)
            .path
    }

    private static func languageCode(for language: String) -> String {
        switch language {
        case "Japanese": "ja"
        case "Thai": "th"
        default: "en"
        }
    }

    private static func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let sourceFormat = buffer.format
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, let channelData = convertedBuffer.floatChannelData else {
            return nil
        }

        let frameLength = Int(convertedBuffer.frameLength)
        guard frameLength > 0 else { return nil }

        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
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
