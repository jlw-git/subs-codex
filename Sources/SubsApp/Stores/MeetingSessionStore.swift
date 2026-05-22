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
    @Published private(set) var currentSourceSubtitle = "Waiting for local audio..."
    @Published private(set) var currentTranslatedSubtitle = ""
    @Published private(set) var isCurrentSourceSubtitleCandidate = false
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

    var statusTitle: String {
        if isRunning { return capture.state.title }
        if isStarting { return "Starting Local Pipeline" }
        if speech.state.failureMessage != nil || capture.state.failureMessage != nil { return "Needs Attention" }
        return sessionState.title
    }

    func toggleCapture() async {
        guard !isStarting else { return }
        isRunning ? await stopCapture() : await startCapture()
    }

    func startCapture() async {
        sessionLogger.info("Starting capture pipeline")
        sessionState = .starting
        currentSourceSubtitle = "Loading \(speechBackend.title) ASR..."
        currentTranslatedSubtitle = "Local translation will warm after capture starts."
        isCurrentSourceSubtitleCandidate = false
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

        await speech.start(language: sourceLanguage, backendKind: speechBackend) { [weak self] result in
            self?.handleRecognition(result)
        }

        guard speech.state == .running else {
            sessionLogger.error("Speech backend failed to start: \(self.speech.state.failureMessage ?? "Unknown error", privacy: .public)")
            sessionState = .failed(speech.state.failureMessage ?? "Local speech recognition did not start.")
            currentSourceSubtitle = "Local ASR is not ready."
            currentTranslatedSubtitle = speech.state.failureMessage ?? "Check the selected local ASR backend."
            capture.onAudioBuffer = nil
            capture.onFirstAudioBuffer = nil
            reliabilityRecorder.recordFailure(stage: "asr_start", message: speech.state.failureMessage ?? "Local speech recognition did not start.")
            reliabilityRecorder.finalize(stopReason: "asr_failed")
            return
        }
        reliabilityRecorder.markASRReady()

        sessionLogger.info("Speech backend running; starting system audio capture")
        currentSourceSubtitle = "Starting local system audio capture..."
        await capture.start()
        if capture.state != .running {
            sessionLogger.error("System audio capture failed to start: \(self.capture.state.failureMessage ?? "Unknown error", privacy: .public)")
            speech.stop()
            sessionState = .failed(capture.state.failureMessage ?? "Local audio capture did not start.")
            currentSourceSubtitle = "Local audio capture is not ready."
            currentTranslatedSubtitle = capture.state.failureMessage ?? "Check macOS audio capture permissions."
            capture.onAudioBuffer = nil
            capture.onFirstAudioBuffer = nil
            reliabilityRecorder.recordFailure(stage: "capture_start", message: capture.state.failureMessage ?? "Local audio capture did not start.")
            reliabilityRecorder.finalize(stopReason: "capture_failed")
        } else {
            sessionLogger.info("Capture pipeline running")
            sessionState = .running
            currentSourceSubtitle = "Listening for local system audio..."
            isCurrentSourceSubtitleCandidate = false
            reliabilityRecorder.markCaptureRunning()
            warmTranslation(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
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
        sessionState = .idle
        reliabilityRecorder.finalize(stopReason: "stopped_by_user")
    }

    func clearTranscript() {
        segments.removeAll()
        lastFinalTranscript = ""
        currentSourceSubtitle = "Waiting for local audio..."
        currentTranslatedSubtitle = ""
        isCurrentSourceSubtitleCandidate = false
        pendingTranslation = nil
        translationWarmupTask?.cancel()
        translationTask?.cancel()
    }

    func applyTranslation(_ translatedText: String, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }

        currentTranslatedSubtitle = translatedText
        if job.isFinal {
            appendFinalSegment(sourceText: job.sourceText, translatedText: translatedText)
        }
    }

    func translationFailed(_ error: Error, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }
        currentTranslatedSubtitle = "Local translation unavailable: \(error.localizedDescription)"
        if job.isFinal {
            appendFinalSegment(sourceText: job.sourceText, translatedText: currentTranslatedSubtitle)
        }
    }

    private func handleRecognition(_ result: SpeechRecognitionResult) {
        guard !result.text.isEmpty else { return }
        currentSourceSubtitle = result.text
        reliabilityRecorder.markRecognition(result.kind, metrics: speech.debugMetrics)

        guard result.kind == .accepted else {
            isCurrentSourceSubtitleCandidate = true
            return
        }

        isCurrentSourceSubtitleCandidate = false
        let job = TranslationJob(
            sourceText: result.text,
            sourceLanguage: Self.localeLanguage(for: sourceLanguage),
            targetLanguage: Self.localeLanguage(for: targetLanguage),
            isFinal: result.isFinal
        )
        pendingTranslation = job
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
                reliabilityRecorder.recordTranslationSuccess(latencyMs: Self.latencyMs(since: startedAt))
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
                if pendingTranslation == nil {
                    currentTranslatedSubtitle = "Local translation ready."
                }
                sessionLogger.info("Translation warmup complete")
            } catch {
                guard !Task.isCancelled else { return }
                sessionLogger.error("Translation warmup failed: \(error.localizedDescription, privacy: .public)")
                reliabilityRecorder.markTranslationWarmupFailed(message: error.localizedDescription)
                currentTranslatedSubtitle = "Local translation unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func appendFinalSegment(sourceText: String, translatedText: String) {
        guard sourceText != lastFinalTranscript else { return }
        lastFinalTranscript = sourceText
        segments.append(
            TranscriptSegment(
                timestamp: Date(),
                speaker: "Meeting audio",
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
