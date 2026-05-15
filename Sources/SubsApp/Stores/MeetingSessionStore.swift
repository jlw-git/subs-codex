import Foundation

@MainActor
final class MeetingSessionStore: ObservableObject {
    @Published var sourceLanguage = "Thai"
    @Published var targetLanguage = "English"
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var currentSourceSubtitle = "Waiting for local audio..."
    @Published private(set) var currentTranslatedSubtitle = ""
    @Published var pendingTranslation: TranslationJob?

    let capture = SystemAudioCaptureService()
    let speech = LocalSpeechRecognitionService()
    private var lastFinalTranscript = ""
    private let translationBackendDeclaration = LocalOnlyBackendDeclaration(
        name: "Apple Translation on-device session",
        purpose: "translation",
        location: .onDevice,
        allowsCloudFallback: false
    )

    var isRunning: Bool {
        capture.state == .running
    }

    func toggleCapture() async {
        isRunning ? await stopCapture() : await startCapture()
    }

    func startCapture() async {
        capture.onAudioBuffer = { [weak self] buffer in
            self?.speech.append(buffer)
        }

        await speech.start(language: sourceLanguage) { [weak self] text, isFinal in
            self?.handleRecognition(text, isFinal: isFinal)
        }

        guard speech.state == .running else { return }

        await capture.start()
        if capture.state != .running {
            speech.stop()
        }
    }

    func stopCapture() async {
        speech.stop()
        capture.onAudioBuffer = nil
        await capture.stop()
    }

    func clearTranscript() {
        segments.removeAll()
        lastFinalTranscript = ""
        currentSourceSubtitle = "Waiting for local audio..."
        currentTranslatedSubtitle = ""
        pendingTranslation = nil
    }

    func applyTranslation(_ translatedText: String, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }

        currentTranslatedSubtitle = translatedText
        if job.isFinal {
            appendFinalSegment(sourceText: job.sourceText, translatedText: translatedText)
        }
    }

    func canUseTranslationBackend() throws {
        try LocalOnlyPolicy.validate(translationBackendDeclaration)
    }

    func translationFailed(_ error: Error, for job: TranslationJob) {
        guard pendingTranslation?.id == job.id else { return }
        currentTranslatedSubtitle = "Local translation unavailable: \(error.localizedDescription)"
        if job.isFinal {
            appendFinalSegment(sourceText: job.sourceText, translatedText: currentTranslatedSubtitle)
        }
    }

    private func handleRecognition(_ text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }
        currentSourceSubtitle = text
        pendingTranslation = TranslationJob(
            sourceText: text,
            sourceLanguage: Self.localeLanguage(for: sourceLanguage),
            targetLanguage: Self.localeLanguage(for: targetLanguage),
            isFinal: isFinal
        )
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
}
