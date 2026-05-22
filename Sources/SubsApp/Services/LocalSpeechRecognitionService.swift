import AVFoundation
import Foundation
import OSLog
import Speech
import WhisperKit

private let speechLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jlwong.Subs",
    category: "Speech"
)

enum SpeechRecognitionResultKind: Equatable {
    case accepted
    case candidate
}

struct SpeechRecognitionResult: Equatable {
    let text: String
    let kind: SpeechRecognitionResultKind
    let isFinal: Bool
}

struct RecognitionDebugMetrics: Equatable {
    var latestRMS: Double = 0
    var skippedQuietChunks: Int = 0
    var filteredLowConfidenceChunks: Int = 0
    var filteredDuplicateChunks: Int = 0
    var candidateChunks: Int = 0
    var acceptedChunks: Int = 0
}

@MainActor
final class LocalSpeechRecognitionService: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestTranscript = "Waiting for local audio..."
    @Published private(set) var activeBackendName = SpeechRecognitionBackendKind.localWhisper.title
    @Published private(set) var debugMetrics = RecognitionDebugMetrics()

    private var activeBackend: SpeechRecognitionBackend?
    private var cachedBackends: [SpeechRecognitionBackendKind: SpeechRecognitionBackend] = [:]

    func start(
        language: String,
        backendKind: SpeechRecognitionBackendKind,
        onRecognition: @escaping (SpeechRecognitionResult) -> Void
    ) async {
        stop()
        state = .requestingPermission
        debugMetrics = RecognitionDebugMetrics()

        let backend = backend(kind: backendKind)
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
            onRecognition: { [weak self] result in
                self?.latestTranscript = result.text
                onRecognition(result)
            },
            onStateChange: { [weak self] state in
                self?.state = state
            },
            onDebugMetricsChange: { [weak self] metrics in
                self?.debugMetrics = metrics
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
        debugMetrics = RecognitionDebugMetrics()
        state = .idle
    }

    private func backend(kind: SpeechRecognitionBackendKind) -> SpeechRecognitionBackend {
        if let backend = cachedBackends[kind] {
            return backend
        }

        let backend = Self.makeBackend(kind: kind)
        cachedBackends[kind] = backend
        return backend
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
        onRecognition: @escaping (SpeechRecognitionResult) -> Void,
        onStateChange: @escaping (CaptureState) -> Void,
        onDebugMetricsChange: @escaping (RecognitionDebugMetrics) -> Void
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

    private let decodeWindowSampleCount = WhisperKit.sampleRate * 8
    private let overlapSampleCount = WhisperKit.sampleRate * 2
    private let minimumChunkRMS = 0.002
    private let overlapDurationSeconds: Float = 2
    private var whisperKit: WhisperKit?
    private var samples: [Float] = []
    private var isTranscribing = false
    private var sessionGeneration = 0
    private var windowSequence = 0
    private var transcribeTask: Task<Void, Never>?
    private var languageCode = "th"
    private var lastAcceptedTranscript = ""
    private var debugMetrics = RecognitionDebugMetrics()
    private var onRecognition: ((SpeechRecognitionResult) -> Void)?
    private var onStateChange: ((CaptureState) -> Void)?
    private var onDebugMetricsChange: ((RecognitionDebugMetrics) -> Void)?

    func start(
        language: String,
        onRecognition: @escaping (SpeechRecognitionResult) -> Void,
        onStateChange: @escaping (CaptureState) -> Void,
        onDebugMetricsChange: @escaping (RecognitionDebugMetrics) -> Void
    ) async {
        self.onRecognition = onRecognition
        self.onStateChange = onStateChange
        self.onDebugMetricsChange = onDebugMetricsChange
        sessionGeneration += 1
        windowSequence = 0
        languageCode = Self.languageCode(for: language)
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        lastAcceptedTranscript = ""
        resetDebugMetrics()
        transcribeTask?.cancel()

        do {
            if whisperKit == nil {
                guard let modelFolder = Self.localModelFolder(), FileManager.default.fileExists(atPath: modelFolder) else {
                    speechLogger.error("Local Whisper model folder is missing")
                    onStateChange(.failed("""
                    Local Whisper ASR is selected for \(language), but no local Whisper model folder was found. Install a WhisperKit Core ML model at ~/Library/Application Support/Subs/Models/whisperkit and retry. Subs stopped here instead of using a cloud fallback.
                    """))
                    return
                }

                let config = WhisperKitConfig(
                    modelFolder: modelFolder,
                    verbose: false,
                    prewarm: false,
                    load: true,
                    download: false
                )
                speechLogger.info("Loading local WhisperKit model")
                whisperKit = try await WhisperKit(config)
                speechLogger.info("Local WhisperKit model loaded")
            } else {
                speechLogger.info("Reusing warm local WhisperKit model")
            }

            onStateChange(.running)
        } catch {
            speechLogger.error("Local Whisper ASR failed to load: \(error.localizedDescription, privacy: .public)")
            onStateChange(.failed("Local Whisper ASR could not load the local model folder: \(error.localizedDescription). Subs did not use a cloud fallback."))
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard whisperKit != nil, let convertedSamples = Self.convertToWhisperSamples(buffer) else { return }
        samples.append(contentsOf: convertedSamples)

        guard samples.count >= decodeWindowSampleCount, !isTranscribing else { return }
        let chunk = Array(samples.prefix(decodeWindowSampleCount))
        let advanceSampleCount = decodeWindowSampleCount - overlapSampleCount
        samples.removeFirst(min(samples.count, advanceSampleCount))
        isTranscribing = true
        windowSequence += 1
        let windowIndex = windowSequence
        let generation = sessionGeneration

        transcribeTask = Task { @MainActor [weak self] in
            await self?.transcribe(chunk, generation: generation, windowIndex: windowIndex)
        }
    }

    func stop() {
        sessionGeneration += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        windowSequence = 0
        lastAcceptedTranscript = ""
        resetDebugMetrics()
        onRecognition = nil
        onStateChange = nil
        onDebugMetricsChange = nil
    }

    private func transcribe(_ audioSamples: [Float], generation: Int, windowIndex: Int) async {
        defer {
            if generation == sessionGeneration {
                isTranscribing = false
            }
        }

        guard generation == sessionGeneration, !Task.isCancelled else { return }
        guard let whisperKit else { return }
        let rms = Self.rmsLevel(for: audioSamples)
        updateDebugMetrics { $0.latestRMS = rms }
        guard rms >= minimumChunkRMS else {
            updateDebugMetrics { $0.skippedQuietChunks += 1 }
            speechLogger.info("Skipping quiet audio chunk, rms: \(rms, privacy: .public)")
            return
        }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: languageCode,
                temperature: 0,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false
            )
            let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)
            let mergedResult = TranscriptionUtilities.mergeTranscriptionResults(results)
            let transcript = mergedResult.text
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard generation == sessionGeneration, !Task.isCancelled, !transcript.isEmpty else { return }
            let segments = mergedResult.segments
            guard Self.isReliableTranscript(transcript, segments: segments) else {
                updateDebugMetrics {
                    $0.filteredLowConfidenceChunks += 1
                    $0.candidateChunks += 1
                }
                speechLogger.info("Filtered low-confidence local Whisper transcript: \(transcript, privacy: .public)")
                onRecognition?(
                    SpeechRecognitionResult(
                        text: transcript,
                        kind: .candidate,
                        isFinal: false
                    )
                )
                return
            }
            let acceptedTranscript = Self.acceptedTranscript(
                from: transcript,
                segments: segments,
                trimLeadingOverlap: windowIndex > 1,
                overlapDurationSeconds: overlapDurationSeconds
            )
            guard !acceptedTranscript.isEmpty else {
                updateDebugMetrics { $0.filteredDuplicateChunks += 1 }
                speechLogger.info("Filtered overlap-only local Whisper transcript: \(transcript, privacy: .public)")
                return
            }
            guard !Self.isDuplicate(acceptedTranscript, previous: lastAcceptedTranscript) else {
                updateDebugMetrics { $0.filteredDuplicateChunks += 1 }
                speechLogger.info("Filtered duplicate local Whisper transcript: \(acceptedTranscript, privacy: .public)")
                return
            }
            lastAcceptedTranscript = acceptedTranscript
            updateDebugMetrics { $0.acceptedChunks += 1 }
            onRecognition?(
                SpeechRecognitionResult(
                    text: acceptedTranscript,
                    kind: .accepted,
                    isFinal: true
                )
            )
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            onStateChange?(.failed("Local Whisper ASR failed while transcribing locally: \(error.localizedDescription). Subs did not use a cloud fallback."))
        }
    }

    private func resetDebugMetrics() {
        debugMetrics = RecognitionDebugMetrics()
        onDebugMetricsChange?(debugMetrics)
    }

    private func updateDebugMetrics(_ update: (inout RecognitionDebugMetrics) -> Void) {
        update(&debugMetrics)
        onDebugMetricsChange?(debugMetrics)
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

    private static func rmsLevel(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { partialResult, sample in
            let value = Double(sample)
            return partialResult + value * value
        }
        return sqrt(sumSquares / Double(samples.count))
    }

    private static func isReliableTranscript(_ transcript: String, segments: [TranscriptionSegment]) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4 else { return false }
        guard !isHighlyRepetitive(normalized) else { return false }
        guard TextUtilities.compressionRatio(of: normalized) <= 2.4 else { return false }
        guard !segments.isEmpty else { return true }

        let noSpeechProb = segments.map(\.noSpeechProb).max() ?? 0
        let avgLogprob = segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        let compressionRatio = segments.map(\.compressionRatio).max() ?? 1

        guard noSpeechProb < 0.6 else { return false }
        guard avgLogprob > -1.0 else { return false }
        guard compressionRatio <= 2.4 else { return false }
        return true
    }

    private static func isDuplicate(_ transcript: String, previous: String) -> Bool {
        guard !previous.isEmpty else { return false }
        return normalizedForComparison(transcript) == normalizedForComparison(previous)
    }

    private static func acceptedTranscript(
        from transcript: String,
        segments: [TranscriptionSegment],
        trimLeadingOverlap: Bool,
        overlapDurationSeconds: Float
    ) -> String {
        guard trimLeadingOverlap, !segments.isEmpty else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmedText = segments
            .filter { $0.end > overlapDurationSeconds }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedText
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func isHighlyRepetitive(_ text: String) -> Bool {
        let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count >= 8 else { return false }

        var longestRun = 1
        var currentRun = 1
        for index in 1..<characters.count {
            if characters[index] == characters[index - 1] {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 1
            }
        }

        return Double(longestRun) / Double(characters.count) >= 0.45
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
        onRecognition: @escaping (SpeechRecognitionResult) -> Void,
        onStateChange: @escaping (CaptureState) -> Void,
        onDebugMetricsChange: @escaping (RecognitionDebugMetrics) -> Void
    ) async {
        onDebugMetricsChange(RecognitionDebugMetrics())
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
                    onRecognition(
                        SpeechRecognitionResult(
                            text: text,
                            kind: .accepted,
                            isFinal: result.isFinal
                        )
                    )
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
