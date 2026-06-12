import Foundation
import OSLog

private let sessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jlwong.Subs",
    category: "Session"
)

@MainActor
final class MeetingSessionStore: ObservableObject {
    @Published var sourceLanguage = "Thai"
    @Published var targetLanguage = "English"
    @Published var speechBackend: SpeechRecognitionBackendKind = .localWhisper
    @Published private(set) var sessionState: CaptureState = .idle
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var currentSourceSubtitle = ""
    @Published private(set) var currentTranslatedSubtitle = ""
    @Published private(set) var isCurrentSourceSubtitleCandidate = false
    @Published private var latestTranslationErrorMessage: String?
    @Published private var readyTranslationPair: String?
    @Published var pendingTranslation: TranslationJob?

    let capture = SystemAudioCaptureService()
    let speech = LocalSpeechRecognitionService()
    let translation = LocalTranslationService()
    let reliabilityRecorder = ReliabilitySessionRecorder()
    private var lastFinalTranscript = ""
    private var translationWarmupTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?

    var isRunning: Bool {
        capture.state == .running
    }

    var isStarting: Bool {
        sessionState == .starting || speech.state == .requestingPermission || capture.state == .requestingPermission
    }

    var primaryActionTitle: String {
        if isRunning { return "Stop" }
        if isStarting { return "Starting" }
        return "Start"
    }

    var primaryActionSystemImage: String {
        if isRunning { return "stop.fill" }
        if isStarting { return "hourglass" }
        return "play.fill"
    }

    var isReadinessCheckDisabled: Bool {
        isRunning || isStarting || translation.translationStatus == .checking
    }

    var readinessSummary: ReadinessSummary {
        if let blockingErrorSummary {
            return ReadinessSummary(
                title: "Action needed",
                detail: blockingErrorSummary.title,
                systemImage: "exclamationmark.triangle",
                tone: .critical
            )
        }

        if isRunning {
            return ReadinessSummary(
                title: "Ready",
                detail: "Capturing \(sourceLanguage) to \(targetLanguage) locally",
                systemImage: "waveform",
                tone: .ready
            )
        }

        if isStarting {
            return ReadinessSummary(
                title: "Starting",
                detail: "Checking local capture and models",
                systemImage: "hourglass",
                tone: .checking
            )
        }

        if selectedTranslationModelStatus != "Installed" {
            return ReadinessSummary(
                title: "Action needed",
                detail: "\(sourceLanguage) translation model is missing",
                systemImage: "shippingbox",
                tone: .critical
            )
        }

        switch translation.translationStatus {
        case .ready:
            guard readyTranslationPair == selectedTranslationPairID else {
                return ReadinessSummary(
                    title: "Not checked",
                    detail: "Check readiness before the meeting",
                    systemImage: "checkmark.shield",
                    tone: .neutral
                )
            }

            return ReadinessSummary(
                title: "Ready",
                detail: "Local \(sourceLanguage) to \(targetLanguage) checked",
                systemImage: "checkmark.shield",
                tone: .ready
            )
        case .checking:
            return ReadinessSummary(
                title: "Checking",
                detail: "Checking local translation runtime",
                systemImage: "hourglass",
                tone: .checking
            )
        case .failed:
            return ReadinessSummary(
                title: "Action needed",
                detail: "Local translation needs attention",
                systemImage: "exclamationmark.triangle",
                tone: .critical
            )
        case .notChecked:
            return ReadinessSummary(
                title: "Not checked",
                detail: "Check readiness before the meeting",
                systemImage: "checkmark.shield",
                tone: .neutral
            )
        }
    }

    var statusTitle: String {
        if isRunning { return capture.state.title }
        if isStarting { return "Starting capture" }
        if speech.state.failureMessage != nil || capture.state.failureMessage != nil { return "Action needed" }
        return sessionState.title
    }

    var livePrimaryText: String {
        if !currentTranslatedSubtitle.isEmpty {
            return currentTranslatedSubtitle
        }

        if let blockingErrorSummary {
            return blockingErrorSummary.title
        }

        if isRunning {
            return currentSourceSubtitle.isEmpty ? "Listening..." : currentSourceSubtitle
        }

        if isStarting {
            return "Starting..."
        }

        return "Press Start to begin"
    }

    var liveSecondarySourceText: String? {
        guard !currentTranslatedSubtitle.isEmpty, !currentSourceSubtitle.isEmpty else {
            return nil
        }

        return currentSourceSubtitle
    }

    var isLivePrimaryPlaceholder: Bool {
        currentTranslatedSubtitle.isEmpty
    }

    var overlayText: String {
        if !currentTranslatedSubtitle.isEmpty {
            return currentTranslatedSubtitle
        }

        if let blockingErrorSummary {
            return blockingErrorSummary.title
        }

        return isRunning || isStarting ? "Listening..." : "Press Start to begin"
    }

    var blockingErrorSummary: BlockingErrorSummary? {
        if case .failed(let message) = capture.state {
            return BlockingErrorSummary(title: "Check system audio", message: message)
        }

        if case .failed(let message) = speech.state {
            return BlockingErrorSummary(title: "Check speech", message: message)
        }

        if let latestTranslationErrorMessage {
            return BlockingErrorSummary(title: "Check translation", message: latestTranslationErrorMessage)
        }

        if case .failed(let message) = translation.translationStatus {
            return BlockingErrorSummary(title: "Check translation", message: message)
        }

        return nil
    }

    var livePipelineStatusItems: [LivePipelineStatusItem] {
        [soundInputStatusItem, processingStatusItem]
    }

    private var soundInputStatusItem: LivePipelineStatusItem {
        if blockingErrorSummary != nil {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Needs permission",
                systemImage: "speaker.slash",
                tone: .critical
            )
        }

        if isStarting {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Starting",
                systemImage: "hourglass",
                tone: .checking
            )
        }

        guard isRunning else {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Off",
                systemImage: "speaker",
                tone: .neutral
            )
        }

        if capture.isReceivingSoundInput {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Receiving",
                systemImage: "waveform",
                tone: .ready
            )
        }

        if capture.hasReceivedSoundInput {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Received",
                systemImage: "waveform",
                tone: .ready
            )
        }

        if capture.hasReceivedAudioInput {
            return LivePipelineStatusItem(
                title: "Sound",
                detail: "Silent",
                systemImage: "speaker.slash",
                tone: .neutral
            )
        }

        return LivePipelineStatusItem(
            title: "Sound",
            detail: "Waiting",
            systemImage: "speaker.wave.2",
            tone: .checking
        )
    }

    private var processingStatusItem: LivePipelineStatusItem {
        if blockingErrorSummary != nil {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Paused",
                systemImage: "pause.circle",
                tone: .critical
            )
        }

        if isStarting {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Starting",
                systemImage: "hourglass",
                tone: .checking
            )
        }

        guard isRunning else {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Idle",
                systemImage: "circle",
                tone: .neutral
            )
        }

        if !currentTranslatedSubtitle.isEmpty {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Showing subtitles",
                systemImage: "captions.bubble",
                tone: .ready
            )
        }

        if pendingTranslation != nil, latestTranslationErrorMessage == nil {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Translating",
                systemImage: "character.book.closed",
                tone: .checking
            )
        }

        if !currentSourceSubtitle.isEmpty {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: isCurrentSourceSubtitleCandidate ? "Checking speech" : "Speech detected",
                systemImage: "waveform.badge.magnifyingglass",
                tone: .checking
            )
        }

        if capture.isReceivingSoundInput {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Processing sound",
                systemImage: "cpu",
                tone: .checking
            )
        }

        if capture.hasReceivedSoundInput {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Waiting for speech",
                systemImage: "ear",
                tone: .checking
            )
        }

        if capture.hasReceivedAudioInput {
            return LivePipelineStatusItem(
                title: "Subs",
                detail: "Waiting for speech",
                systemImage: "ear",
                tone: .neutral
            )
        }

        return LivePipelineStatusItem(
            title: "Subs",
            detail: "Waiting for sound",
            systemImage: "ear",
            tone: .neutral
        )
    }

    func toggleCapture() async {
        guard !isStarting else { return }
        isRunning ? await stopCapture() : await startCapture()
    }

    func startCapture() async {
        sessionLogger.info("Starting capture pipeline")
        sessionState = .starting
        currentSourceSubtitle = ""
        currentTranslatedSubtitle = ""
        isCurrentSourceSubtitleCandidate = false
        latestTranslationErrorMessage = nil
        pendingTranslation = nil
        translationWarmupTask?.cancel()
        translationTask?.cancel()
        reliabilityRecorder.start(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            asrBackend: speechBackend.title,
            translationBackend: translation.activeBackendName
        )

        capture.onAudioBuffer = { [weak self] buffer in
            self?.speech.append(buffer)
        }
        capture.onFirstAudioBuffer = { [weak self] in
            self?.reliabilityRecorder.markFirstAudioBuffer()
        }

        warmTranslation(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)

        await speech.start(language: sourceLanguage, backendKind: speechBackend) { [weak self] result in
            self?.handleRecognition(result)
        }

        guard speech.state == .running else {
            sessionLogger.error("Speech backend failed to start: \(self.speech.state.failureMessage ?? "Unknown error", privacy: .public)")
            sessionState = .failed(speech.state.failureMessage ?? "Speech recognition did not start.")
            currentSourceSubtitle = ""
            currentTranslatedSubtitle = ""
            capture.onAudioBuffer = nil
            capture.onFirstAudioBuffer = nil
            translationWarmupTask?.cancel()
            reliabilityRecorder.recordFailure(stage: "asr_start", message: speech.state.failureMessage ?? "Speech recognition did not start.")
            reliabilityRecorder.finalize(stopReason: "asr_failed")
            return
        }
        reliabilityRecorder.markASRReady()

        sessionLogger.info("Speech backend running; starting system audio capture")
        await capture.start()
        if capture.state != .running {
            sessionLogger.error("System audio capture failed to start: \(self.capture.state.failureMessage ?? "Unknown error", privacy: .public)")
            speech.stop()
            sessionState = .failed(capture.state.failureMessage ?? "Audio capture did not start.")
            currentSourceSubtitle = ""
            currentTranslatedSubtitle = ""
            capture.onAudioBuffer = nil
            capture.onFirstAudioBuffer = nil
            translationWarmupTask?.cancel()
            reliabilityRecorder.recordFailure(stage: "capture_start", message: capture.state.failureMessage ?? "Audio capture did not start.")
            reliabilityRecorder.finalize(stopReason: "capture_failed")
        } else {
            sessionLogger.info("Capture pipeline running")
            sessionState = .running
            isCurrentSourceSubtitleCandidate = false
            reliabilityRecorder.markCaptureRunning()
        }
    }

    func stopCapture() async {
        speech.stop()
        capture.onAudioBuffer = nil
        capture.onFirstAudioBuffer = nil
        await capture.stop()
        translationWarmupTask?.cancel()
        translationTask?.cancel()
        isCurrentSourceSubtitleCandidate = false
        currentSourceSubtitle = ""
        currentTranslatedSubtitle = ""
        latestTranslationErrorMessage = nil
        pendingTranslation = nil
        sessionState = .idle
        reliabilityRecorder.finalize(stopReason: "stopped_by_user")
    }

    func clearTranscript() {
        segments.removeAll()
        lastFinalTranscript = ""
        currentSourceSubtitle = ""
        currentTranslatedSubtitle = ""
        isCurrentSourceSubtitleCandidate = false
        latestTranslationErrorMessage = nil
        pendingTranslation = nil
        translationWarmupTask?.cancel()
        translationTask?.cancel()
    }

    func checkReadiness() async {
        guard !isReadinessCheckDisabled else { return }
        latestTranslationErrorMessage = nil
        let checkedPair = selectedTranslationPairID
        let checkedSourceLanguage = Self.localeLanguage(for: sourceLanguage)
        let checkedTargetLanguage = Self.localeLanguage(for: targetLanguage)

        do {
            try LocalOnlyPolicy.validate(speechBackend.declaration)
            try await translation.prepare(
                sourceLanguage: checkedSourceLanguage,
                targetLanguage: checkedTargetLanguage
            )
            readyTranslationPair = checkedPair
        } catch {
            readyTranslationPair = nil
            latestTranslationErrorMessage = error.localizedDescription
        }
    }

    func applyTranslation(_ translatedText: String, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }

        latestTranslationErrorMessage = nil
        currentTranslatedSubtitle = translatedText
        if job.isFinal {
            appendFinalSegment(sourceText: job.sourceText, translatedText: translatedText)
        }
    }

    func translationFailed(_ error: Error, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }
        latestTranslationErrorMessage = error.localizedDescription
    }

    private func handleRecognition(_ result: SpeechRecognitionResult) {
        guard !result.text.isEmpty else { return }
        currentSourceSubtitle = result.text
        currentTranslatedSubtitle = ""
        latestTranslationErrorMessage = nil
        reliabilityRecorder.markRecognition(result.kind, metrics: speech.debugMetrics)

        let job = TranslationJob(
            sourceText: result.text,
            sourceLanguage: Self.localeLanguage(for: sourceLanguage),
            targetLanguage: Self.localeLanguage(for: targetLanguage),
            isFinal: result.isFinal
        )
        pendingTranslation = job
        isCurrentSourceSubtitleCandidate = result.kind != .accepted
        enqueueTranslation(job)
    }

    private func enqueueTranslation(_ job: TranslationJob) {
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            reliabilityRecorder.recordTranslationAttempt()

            do {
                let translatedText = try await translation.translate(job)
                guard !Task.isCancelled else { return }
                reliabilityRecorder.recordTranslationSuccess(
                    latencyMs: Self.latencyMs(since: startedAt),
                    kind: job.isFinal ? .accepted : .candidate
                )
                applyTranslation(translatedText, for: job)
            } catch {
                guard !Task.isCancelled else { return }
                reliabilityRecorder.recordTranslationFailure(
                    latencyMs: Self.latencyMs(since: startedAt),
                    message: error.localizedDescription
                )
                translationFailed(error, for: job)
            }
        }
    }

    private func warmTranslation(sourceLanguage: String, targetLanguage: String) {
        translationWarmupTask?.cancel()
        let source = Self.localeLanguage(for: sourceLanguage)
        let target = Self.localeLanguage(for: targetLanguage)
        sessionLogger.info("Starting translation warmup")

        translationWarmupTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await translation.prepare(sourceLanguage: source, targetLanguage: target)
                guard !Task.isCancelled else { return }
                reliabilityRecorder.markTranslationWarmupReady()
                readyTranslationPair = "\(sourceLanguage)-\(targetLanguage)"
                latestTranslationErrorMessage = nil
                sessionLogger.info("Translation warmup complete")
            } catch {
                guard !Task.isCancelled else { return }
                sessionLogger.error("Translation warmup failed: \(error.localizedDescription, privacy: .public)")
                reliabilityRecorder.markTranslationWarmupFailed(message: error.localizedDescription)
                readyTranslationPair = nil
                latestTranslationErrorMessage = error.localizedDescription
            }
        }
    }

    private var selectedTranslationPairID: String {
        "\(sourceLanguage)-\(targetLanguage)"
    }

    private var selectedTranslationModelStatus: String {
        switch sourceLanguage {
        case "Japanese": translation.japaneseModelStatus
        case "Thai": translation.thaiModelStatus
        default: "Missing"
        }
    }

    private func appendFinalSegment(sourceText: String, translatedText: String) {
        guard sourceText != lastFinalTranscript else { return }
        lastFinalTranscript = sourceText
        segments.append(
            TranscriptSegment(
                timestamp: Date(),
                speaker: "Audio",
                sourceText: sourceText,
                translatedText: translatedText,
                isFinal: true
            )
        )
    }

    private static func localeLanguage(for language: String) -> Locale.Language {
        switch language {
        case "Japanese": Locale.Language(identifier: "ja")
        case "Thai": Locale.Language(identifier: "th")
        default: Locale.Language(identifier: "en")
        }
    }

    private static func latencyMs(since startDate: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(startDate) * 1000).rounded()))
    }
}

struct BlockingErrorSummary: Equatable {
    let title: String
    let message: String
}

struct ReadinessSummary: Equatable {
    enum Tone: Equatable {
        case ready
        case checking
        case critical
        case neutral
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone
}

struct LivePipelineStatusItem: Equatable, Identifiable {
    let title: String
    let detail: String
    let systemImage: String
    let tone: ReadinessSummary.Tone

    var id: String { title }
}
