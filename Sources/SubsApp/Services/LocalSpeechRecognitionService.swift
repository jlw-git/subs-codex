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
    @Published private(set) var latestTranscript = "Waiting for audio..."
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
        latestTranscript = "Waiting for audio..."
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
        case .liveFastWhisperCpp: WhisperCppSpeechRecognitionBackend()
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
    let displayName = "Accurate (WhisperKit medium)"
    let declaration = LocalOnlyBackendDeclaration(
        name: "Local Whisper ASR",
        purpose: "speech-to-text",
        location: .onDevice,
        allowsCloudFallback: false
    )

    private let decodeWindowSampleCount = WhisperKit.sampleRate * 3
    private let overlapSampleCount = WhisperKit.sampleRate * 3 / 4
    private let minimumChunkRMS = 0.00005
    private let overlapDurationSeconds: Float = 0.75
    private var whisperKit: WhisperKit?
    private var sampleConverter: AVAudioConverter?
    private var sampleConverterSourceFormat: AVAudioFormat?
    private var sampleConverterTargetFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var isTranscribing = false
    private var sessionGeneration = 0
    private var windowSequence = 0
    private var transcribeTask: Task<Void, Never>?
    private var languageCode = "th"
    private var lastAcceptedTranscript = ""
    private var lastCandidateTranscript = ""
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
        lastCandidateTranscript = ""
        resetDebugMetrics()
        transcribeTask?.cancel()

        do {
            if whisperKit == nil {
                guard let modelFolder = Self.localModelFolder(), FileManager.default.fileExists(atPath: modelFolder) else {
                    speechLogger.error("Local Whisper model folder is missing")
                    onStateChange(.failed("""
                    WhisperKit is selected for \(language), but the model is missing. Install it at ~/Library/Application Support/Subs/Models/whisperkit and retry. Subs will not use cloud speech recognition.
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
            onStateChange(.failed("WhisperKit could not load the model: \(error.localizedDescription). Subs will not use cloud speech recognition."))
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard whisperKit != nil, let convertedSamples = convertToWhisperSamples(buffer) else { return }
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
        lastCandidateTranscript = ""
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
            let result = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options) { [weak self] progress in
                let candidate = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor [weak self] in
                    self?.publishCandidate(candidate, generation: generation)
                }
                return true
            }
            guard let result else { return }
            let transcript = result.text
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard generation == sessionGeneration, !Task.isCancelled, !transcript.isEmpty else { return }
            let segments = result.segments
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
            onStateChange?(.failed("WhisperKit could not transcribe: \(error.localizedDescription). Subs will not use cloud speech recognition."))
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

    private func publishCandidate(_ transcript: String, generation: Int) {
        guard generation == sessionGeneration, !transcript.isEmpty else { return }
        guard transcript.count >= 4, !Self.isHighlyRepetitive(transcript) else { return }
        guard !Self.isDuplicate(transcript, previous: lastCandidateTranscript),
              !Self.isDuplicate(transcript, previous: lastAcceptedTranscript) else {
            return
        }

        lastCandidateTranscript = transcript
        updateDebugMetrics { $0.candidateChunks += 1 }
        onRecognition?(
            SpeechRecognitionResult(
                text: transcript,
                kind: .candidate,
                isFinal: false
            )
        )
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

    private func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
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
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        let converter = sampleConverter(from: sourceFormat, to: targetFormat)
        converter.reset()

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

    private func sampleConverter(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> AVAudioConverter {
        if let sampleConverter,
           sampleConverterSourceFormat == sourceFormat,
           sampleConverterTargetFormat == targetFormat {
            return sampleConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!
        sampleConverter = converter
        sampleConverterSourceFormat = sourceFormat
        sampleConverterTargetFormat = targetFormat
        return converter
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
private final class WhisperCppSpeechRecognitionBackend: SpeechRecognitionBackend {
    let displayName = "Live Fast (whisper.cpp turbo)"
    let declaration = LocalOnlyBackendDeclaration(
        name: "whisper.cpp local ASR",
        purpose: "speech-to-text",
        location: .onDevice,
        allowsCloudFallback: false
    )

    private let decodeWindowSampleCount = WhisperKit.sampleRate * 2
    private let overlapSampleCount = WhisperKit.sampleRate / 2
    private let minimumChunkRMS = 0.00005
    private var sampleConverter: AVAudioConverter?
    private var sampleConverterSourceFormat: AVAudioFormat?
    private var sampleConverterTargetFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var isTranscribing = false
    private var sessionGeneration = 0
    private var transcribeTask: Task<Void, Never>?
    private var languageCode = "th"
    private var lastAcceptedTranscript = ""
    private var lastCandidateTranscript = ""
    private var debugMetrics = RecognitionDebugMetrics()
    private var worker: WhisperCppWorker?
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
        languageCode = Self.languageCode(for: language)
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        lastAcceptedTranscript = ""
        lastCandidateTranscript = ""
        resetDebugMetrics()
        transcribeTask?.cancel()

        do {
            guard FileManager.default.isExecutableFile(atPath: Self.executablePath()) else {
                onStateChange(.failed("""
                Live Fast needs whisper.cpp at \(Self.executablePath()). Run script/setup_whisper_cpp.sh --verify and retry. Subs will not use cloud speech recognition.
                """))
                return
            }

            guard FileManager.default.fileExists(atPath: Self.turboModelPath()) else {
                onStateChange(.failed("""
                Live Fast needs the whisper.cpp model at \(Self.turboModelPath()). Run script/setup_whisper_cpp.sh --verify and retry. Subs will not use cloud speech recognition.
                """))
                return
            }

            let worker = try workerInstance()
            try await worker.verify(
                executablePath: Self.executablePath(),
                modelPath: Self.turboModelPath()
            )
            onStateChange(.running)
        } catch {
            onStateChange(.failed("Live Fast could not start whisper.cpp: \(error.localizedDescription). Subs will not use cloud speech recognition."))
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let convertedSamples = convertToWhisperSamples(buffer) else { return }
        samples.append(contentsOf: convertedSamples)

        guard samples.count >= decodeWindowSampleCount, !isTranscribing else { return }
        let chunk = Array(samples.prefix(decodeWindowSampleCount))
        let advanceSampleCount = decodeWindowSampleCount - overlapSampleCount
        samples.removeFirst(min(samples.count, advanceSampleCount))
        isTranscribing = true
        let generation = sessionGeneration

        transcribeTask = Task { @MainActor [weak self] in
            await self?.transcribe(chunk, generation: generation)
        }
    }

    func stop() {
        sessionGeneration += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        lastAcceptedTranscript = ""
        lastCandidateTranscript = ""
        resetDebugMetrics()
        onRecognition = nil
        onStateChange = nil
        onDebugMetricsChange = nil
    }

    private func transcribe(_ audioSamples: [Float], generation: Int) async {
        defer {
            if generation == sessionGeneration {
                isTranscribing = false
            }
        }

        guard generation == sessionGeneration, !Task.isCancelled else { return }
        let rms = Self.rmsLevel(for: audioSamples)
        updateDebugMetrics { $0.latestRMS = rms }
        guard rms >= minimumChunkRMS else {
            updateDebugMetrics { $0.skippedQuietChunks += 1 }
            return
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subs-whisper-cpp-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try Self.writeWAV(samples: audioSamples, to: audioURL)
            let response = try await workerInstance().transcribe(
                audioPath: audioURL.path,
                executablePath: Self.executablePath(),
                modelPath: Self.turboModelPath(),
                languageCode: languageCode
            )

            let transcript = (response.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == sessionGeneration, !Task.isCancelled, !transcript.isEmpty else { return }
            guard transcript.count >= 4, !Self.isHighlyRepetitive(transcript) else {
                updateDebugMetrics { $0.filteredLowConfidenceChunks += 1 }
                return
            }

            if !Self.isDuplicate(transcript, previous: lastCandidateTranscript),
               !Self.isDuplicate(transcript, previous: lastAcceptedTranscript) {
                lastCandidateTranscript = transcript
                updateDebugMetrics { $0.candidateChunks += 1 }
                onRecognition?(
                    SpeechRecognitionResult(
                        text: transcript,
                        kind: .candidate,
                        isFinal: false
                    )
                )
            }

            guard !Self.isDuplicate(transcript, previous: lastAcceptedTranscript) else {
                updateDebugMetrics { $0.filteredDuplicateChunks += 1 }
                return
            }

            lastAcceptedTranscript = transcript
            updateDebugMetrics { $0.acceptedChunks += 1 }
            onRecognition?(
                SpeechRecognitionResult(
                    text: transcript,
                    kind: .accepted,
                    isFinal: true
                )
            )
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            onStateChange?(.failed("Live Fast could not transcribe: \(error.localizedDescription). Subs will not use cloud speech recognition."))
        }
    }

    private func workerInstance() throws -> WhisperCppWorker {
        if let worker {
            return worker
        }

        guard let scriptURL = Bundle.module.url(forResource: "whisper_cpp_worker", withExtension: "py") else {
            throw WhisperCppRecognitionError.runnerMissing
        }

        let worker = WhisperCppWorker(
            pythonPath: Self.pythonPath(),
            scriptPath: scriptURL.path
        )
        self.worker = worker
        return worker
    }

    private func resetDebugMetrics() {
        debugMetrics = RecognitionDebugMetrics()
        onDebugMetricsChange?(debugMetrics)
    }

    private func updateDebugMetrics(_ update: (inout RecognitionDebugMetrics) -> Void) {
        update(&debugMetrics)
        onDebugMetricsChange?(debugMetrics)
    }

    private func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
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
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        let converter = sampleConverter(from: sourceFormat, to: targetFormat)
        converter.reset()

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

    private func sampleConverter(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> AVAudioConverter {
        if let sampleConverter,
           sampleConverterSourceFormat == sourceFormat,
           sampleConverterTargetFormat == targetFormat {
            return sampleConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!
        sampleConverter = converter
        sampleConverterSourceFormat = sourceFormat
        sampleConverterTargetFormat = targetFormat
        return converter
    }

    private static func writeWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WhisperCppRecognitionError.audioEncodingFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else {
            throw WhisperCppRecognitionError.audioEncodingFailed
        }
        samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func languageCode(for language: String) -> String {
        switch language {
        case "Japanese": "ja"
        case "Thai": "th"
        default: "en"
        }
    }

    private static func rmsLevel(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { partialResult, sample in
            let value = Double(sample)
            return partialResult + value * value
        }
        return sqrt(sumSquares / Double(samples.count))
    }

    private static func isDuplicate(_ transcript: String, previous: String) -> Bool {
        guard !previous.isEmpty else { return false }
        return normalizedForComparison(transcript) == normalizedForComparison(previous)
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

    private static func executablePath() -> String {
        let configuredPath = ProcessInfo.processInfo.environment["SUBS_WHISPER_CPP_CLI"] ?? ""
        if !configuredPath.isEmpty {
            return expandingTilde(in: configuredPath)
        }

        return applicationSupportURL()
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("whisper-cpp", isDirectory: true)
            .appendingPathComponent("whisper-cli")
            .path
    }

    private static func turboModelPath() -> String {
        let configuredPath = ProcessInfo.processInfo.environment["SUBS_WHISPER_CPP_TURBO_MODEL"] ?? ""
        if !configuredPath.isEmpty {
            return expandingTilde(in: configuredPath)
        }

        return applicationSupportURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("whisper-cpp", isDirectory: true)
            .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
            .path
    }

    private static func pythonPath() -> String {
        let configuredPath = ProcessInfo.processInfo.environment["SUBS_WHISPER_CPP_PYTHON"] ?? ""
        return configuredPath.isEmpty ? "/usr/bin/python3" : expandingTilde(in: configuredPath)
    }

    private static func applicationSupportURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport.appendingPathComponent("Subs", isDirectory: true)
    }

    private static func expandingTilde(in path: String) -> String {
        (path as NSString).expandingTildeInPath
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
            onStateChange(.failed("Allow Speech Recognition in System Settings."))
            return
        }

        let locale = Locale(identifier: Self.localeIdentifier(for: language))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            onStateChange(.failed("Speech recognition is not available for \(language)."))
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            onStateChange(.failed("Apple Speech is not available on device for \(language). Subs will not use cloud speech recognition."))
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
                    onStateChange(.failed("Speech recognition stopped: \(error.localizedDescription)"))
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

private enum WhisperCppWorkerCommand: String, Codable {
    case verify
    case transcribe
}

private struct WhisperCppWorkerRequest: Codable {
    let id: String
    let command: WhisperCppWorkerCommand
    let executablePath: String
    let modelPath: String
    let audioPath: String?
    let languageCode: String?
}

private struct WhisperCppWorkerResponse: Codable {
    let id: String
    let ok: Bool
    let text: String?
    let error: String?
}

private final class WhisperCppWorker: @unchecked Sendable {
    private let pythonPath: String
    private let scriptPath: String
    private let queue = DispatchQueue(label: "com.jlwong.Subs.WhisperCppWorker")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?

    init(pythonPath: String, scriptPath: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    func verify(executablePath: String, modelPath: String) async throws {
        let response = try await send(
            WhisperCppWorkerRequest(
                id: UUID().uuidString,
                command: .verify,
                executablePath: executablePath,
                modelPath: modelPath,
                audioPath: nil,
                languageCode: nil
            )
        )
        guard response.ok else {
            throw WhisperCppRecognitionError.runtimeFailed(response.error ?? "whisper.cpp worker verification failed.")
        }
    }

    func transcribe(
        audioPath: String,
        executablePath: String,
        modelPath: String,
        languageCode: String
    ) async throws -> WhisperCppWorkerResponse {
        let response = try await send(
            WhisperCppWorkerRequest(
                id: UUID().uuidString,
                command: .transcribe,
                executablePath: executablePath,
                modelPath: modelPath,
                audioPath: audioPath,
                languageCode: languageCode
            )
        )
        guard response.ok else {
            throw WhisperCppRecognitionError.runtimeFailed(response.error ?? "whisper.cpp worker failed without an error message.")
        }
        return response
    }

    private func send(_ request: WhisperCppWorkerRequest) async throws -> WhisperCppWorkerResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startIfNeeded()

                    let requestData = try JSONEncoder().encode(request)
                    guard var requestLine = String(data: requestData, encoding: .utf8) else {
                        throw WhisperCppRecognitionError.runtimeFailed("Could not encode whisper.cpp worker request.")
                    }
                    requestLine.append("\n")

                    guard let inputHandle = self.inputHandle,
                          let outputHandle = self.outputHandle else {
                        throw WhisperCppRecognitionError.runtimeFailed("whisper.cpp worker pipes are unavailable.")
                    }

                    try inputHandle.write(contentsOf: Data(requestLine.utf8))
                    guard let lineData = try outputHandle.readLineData() else {
                        let errorOutput = self.readWorkerError()
                        self.stop()
                        throw WhisperCppRecognitionError.runtimeFailed(
                            errorOutput.isEmpty ? "whisper.cpp worker exited without a response." : errorOutput
                        )
                    }

                    let response = try JSONDecoder().decode(WhisperCppWorkerResponse.self, from: lineData)
                    guard response.id == request.id else {
                        throw WhisperCppRecognitionError.runtimeFailed("whisper.cpp worker response id did not match the request.")
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "--worker"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
    }

    private func stop() {
        process?.terminate()
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }

    private func readWorkerError() -> String {
        guard let errorHandle else { return "" }
        let data = errorHandle.availableData
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension FileHandle {
    func readLineData() throws -> Data? {
        var data = Data()

        while true {
            let chunk = try read(upToCount: 1)
            guard let chunk, !chunk.isEmpty else {
                return data.isEmpty ? nil : data
            }

            if chunk == Data([0x0A]) {
                return data
            }

            data.append(chunk)
        }
    }
}

private enum WhisperCppRecognitionError: LocalizedError {
    case runnerMissing
    case audioEncodingFailed
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .runnerMissing:
            "The bundled whisper.cpp worker is missing from the app resources."
        case .audioEncodingFailed:
            "Could not encode the local audio chunk for whisper.cpp."
        case .runtimeFailed(let message):
            message
        }
    }
}
