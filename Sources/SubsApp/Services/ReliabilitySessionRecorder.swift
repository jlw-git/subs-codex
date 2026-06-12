import Foundation

struct ReliabilityReportFileURLs: Equatable {
    let json: URL
    let markdown: URL
}

struct ReliabilitySessionReport: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let stopReason: String
    let sourceLanguage: String
    let targetLanguage: String
    let asrBackend: String
    let translationBackend: String
    let timings: ReliabilityStartupTimings
    let recognition: ReliabilityRecognitionMetrics
    let translation: ReliabilityTranslationMetrics
    let failures: [ReliabilityFailureRecord]

    var id: UUID { sessionID }
}

struct ReliabilityStartupTimings: Codable, Equatable {
    var asrReadyMs: Int?
    var captureRunningMs: Int?
    var firstAudioBufferMs: Int?
    var translationWarmupReadyMs: Int?
    var translationWarmupFailedMs: Int?
    var firstCandidateSubtitleMs: Int?
    var firstAcceptedSubtitleMs: Int?
    var firstTranslatedSubtitleMs: Int?
    var firstTranslatedDraftSubtitleMs: Int?
    var firstTranslatedCorrectedSubtitleMs: Int?
}

struct ReliabilityRecognitionMetrics: Codable, Equatable {
    var latestRMS: Double
    var skippedQuietChunks: Int
    var filteredLowConfidenceChunks: Int
    var filteredDuplicateChunks: Int
    var candidateChunks: Int
    var acceptedChunks: Int

    init(metrics: RecognitionDebugMetrics = RecognitionDebugMetrics()) {
        latestRMS = metrics.latestRMS
        skippedQuietChunks = metrics.skippedQuietChunks
        filteredLowConfidenceChunks = metrics.filteredLowConfidenceChunks
        filteredDuplicateChunks = metrics.filteredDuplicateChunks
        candidateChunks = metrics.candidateChunks
        acceptedChunks = metrics.acceptedChunks
    }
}

struct ReliabilityTranslationMetrics: Codable, Equatable {
    var attempts: Int = 0
    var successes: Int = 0
    var failures: Int = 0
    var minLatencyMs: Int?
    var averageLatencyMs: Double?
    var maxLatencyMs: Int?

    fileprivate var totalLatencyMs: Int = 0

    private enum CodingKeys: String, CodingKey {
        case attempts
        case successes
        case failures
        case minLatencyMs
        case averageLatencyMs
        case maxLatencyMs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attempts = try container.decode(Int.self, forKey: .attempts)
        successes = try container.decode(Int.self, forKey: .successes)
        failures = try container.decode(Int.self, forKey: .failures)
        minLatencyMs = try container.decodeIfPresent(Int.self, forKey: .minLatencyMs)
        averageLatencyMs = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMs)
        maxLatencyMs = try container.decodeIfPresent(Int.self, forKey: .maxLatencyMs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(successes, forKey: .successes)
        try container.encode(failures, forKey: .failures)
        try container.encodeIfPresent(minLatencyMs, forKey: .minLatencyMs)
        try container.encodeIfPresent(averageLatencyMs, forKey: .averageLatencyMs)
        try container.encodeIfPresent(maxLatencyMs, forKey: .maxLatencyMs)
    }

    mutating func recordAttempt() {
        attempts += 1
    }

    mutating func recordSuccess(latencyMs: Int) {
        successes += 1
        recordLatency(latencyMs)
    }

    mutating func recordFailure(latencyMs: Int) {
        failures += 1
        recordLatency(latencyMs)
    }

    private mutating func recordLatency(_ latencyMs: Int) {
        minLatencyMs = min(minLatencyMs ?? latencyMs, latencyMs)
        maxLatencyMs = max(maxLatencyMs ?? latencyMs, latencyMs)
        totalLatencyMs += latencyMs
        let completed = successes + failures
        if completed > 0 {
            averageLatencyMs = (Double(totalLatencyMs) / Double(completed) * 10).rounded() / 10
        }
    }
}

struct ReliabilityFailureRecord: Codable, Equatable {
    let stage: String
    let timestamp: Date
    let message: String
}

@MainActor
final class ReliabilitySessionRecorder: ObservableObject {
    nonisolated static let schemaVersion = 2

    @Published private(set) var latestReport: ReliabilitySessionReport?
    @Published private(set) var latestReportFileURLs: ReliabilityReportFileURLs?
    @Published private(set) var latestWriteError: String?

    let reportsDirectoryURL: URL

    private let dateProvider: () -> Date
    private let idProvider: () -> UUID
    private var activeSession: ActiveReliabilitySession?

    init(
        reportsDirectoryURL: URL = ReliabilitySessionRecorder.defaultReportsDirectoryURL(),
        dateProvider: @escaping () -> Date = Date.init,
        idProvider: @escaping () -> UUID = UUID.init
    ) {
        self.reportsDirectoryURL = reportsDirectoryURL
        self.dateProvider = dateProvider
        self.idProvider = idProvider
    }

    nonisolated static func defaultReportsDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("Subs", isDirectory: true)
            .appendingPathComponent("ReliabilityReports", isDirectory: true)
    }

    func start(
        sourceLanguage: String,
        targetLanguage: String,
        asrBackend: String,
        translationBackend: String
    ) {
        latestWriteError = nil
        let now = dateProvider()
        activeSession = ActiveReliabilitySession(
            sessionID: idProvider(),
            startedAt: now,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            asrBackend: asrBackend,
            translationBackend: translationBackend
        )
    }

    func markASRReady() {
        let elapsed = elapsedMs()
        activeSession?.setFirstTiming(\.asrReadyMs, elapsed)
    }

    func markCaptureRunning() {
        let elapsed = elapsedMs()
        activeSession?.setFirstTiming(\.captureRunningMs, elapsed)
    }

    func markFirstAudioBuffer() {
        let elapsed = elapsedMs()
        activeSession?.setFirstTiming(\.firstAudioBufferMs, elapsed)
    }

    func markTranslationWarmupReady() {
        let elapsed = elapsedMs()
        activeSession?.setFirstTiming(\.translationWarmupReadyMs, elapsed)
    }

    func markTranslationWarmupFailed(message: String) {
        let elapsed = elapsedMs()
        activeSession?.setFirstTiming(\.translationWarmupFailedMs, elapsed)
        recordFailure(stage: "translation_warmup", message: message)
    }

    func markRecognition(_ kind: SpeechRecognitionResultKind, metrics: RecognitionDebugMetrics) {
        let elapsed = elapsedMs()
        activeSession?.recognition = ReliabilityRecognitionMetrics(metrics: metrics)
        switch kind {
        case .accepted:
            activeSession?.setFirstTiming(\.firstAcceptedSubtitleMs, elapsed)
        case .candidate:
            activeSession?.setFirstTiming(\.firstCandidateSubtitleMs, elapsed)
        }
    }

    func recordTranslationAttempt() {
        activeSession?.translation.recordAttempt()
    }

    func recordTranslationSuccess(latencyMs: Int, kind: SpeechRecognitionResultKind) {
        let elapsed = elapsedMs()
        activeSession?.translation.recordSuccess(latencyMs: latencyMs)
        activeSession?.setFirstTiming(\.firstTranslatedSubtitleMs, elapsed)
        switch kind {
        case .candidate:
            activeSession?.setFirstTiming(\.firstTranslatedDraftSubtitleMs, elapsed)
        case .accepted:
            activeSession?.setFirstTiming(\.firstTranslatedCorrectedSubtitleMs, elapsed)
        }
    }

    func recordTranslationFailure(latencyMs: Int, message: String) {
        activeSession?.translation.recordFailure(latencyMs: latencyMs)
        recordFailure(stage: "translation", message: message)
    }

    func recordFailure(stage: String, message: String) {
        guard activeSession != nil else { return }
        activeSession?.failures.append(
            ReliabilityFailureRecord(
                stage: stage,
                timestamp: dateProvider(),
                message: message
            )
        )
    }

    @discardableResult
    func finalize(stopReason: String) -> ReliabilitySessionReport? {
        guard let session = activeSession else { return nil }
        activeSession = nil

        let report = session.report(endedAt: dateProvider(), stopReason: stopReason)
        latestReport = report
        latestReportFileURLs = nil

        do {
            latestReportFileURLs = try write(report)
            latestWriteError = nil
        } catch {
            latestWriteError = error.localizedDescription
        }

        return report
    }

    private func elapsedMs() -> Int {
        guard let activeSession else { return 0 }
        return max(0, Int((dateProvider().timeIntervalSince(activeSession.startedAt) * 1000).rounded()))
    }

    private func write(_ report: ReliabilitySessionReport) throws -> ReliabilityReportFileURLs {
        try FileManager.default.createDirectory(at: reportsDirectoryURL, withIntermediateDirectories: true)

        let baseName = "reliability_session_\(Self.fileTimestampFormatter.string(from: report.startedAt))_\(report.sessionID.uuidString.prefix(8).lowercased())"
        let jsonURL = reportsDirectoryURL.appendingPathComponent("\(baseName).json")
        let markdownURL = reportsDirectoryURL.appendingPathComponent("\(baseName).md")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        try markdown(for: report).write(to: markdownURL, atomically: true, encoding: .utf8)

        return ReliabilityReportFileURLs(json: jsonURL, markdown: markdownURL)
    }

    private func markdown(for report: ReliabilitySessionReport) -> String {
        let timings = report.timings
        let translation = report.translation
        let failures = report.failures.isEmpty
            ? "- None"
            : report.failures.map { "- \($0.stage): \($0.message)" }.joined(separator: "\n")

        return """
        # Subs Reliability Session

        - Schema version: \(report.schemaVersion)
        - Session ID: \(report.sessionID.uuidString)
        - Started: \(Self.displayDateFormatter.string(from: report.startedAt))
        - Ended: \(Self.displayDateFormatter.string(from: report.endedAt))
        - Stop reason: \(report.stopReason)
        - Language: \(report.sourceLanguage) to \(report.targetLanguage)
        - Speech model: \(report.asrBackend)
        - Translation: \(report.translationBackend)

        ## Startup

        | Event | Milliseconds |
        | --- | ---: |
        | Speech ready | \(Self.display(timings.asrReadyMs)) |
        | Capture running | \(Self.display(timings.captureRunningMs)) |
        | First audio | \(Self.display(timings.firstAudioBufferMs)) |
        | Translation ready | \(Self.display(timings.translationWarmupReadyMs)) |
        | Translation failed | \(Self.display(timings.translationWarmupFailedMs)) |
        | First draft | \(Self.display(timings.firstCandidateSubtitleMs)) |
        | First accepted | \(Self.display(timings.firstAcceptedSubtitleMs)) |
        | First English | \(Self.display(timings.firstTranslatedSubtitleMs)) |
        | First English draft | \(Self.display(timings.firstTranslatedDraftSubtitleMs)) |
        | First accepted English | \(Self.display(timings.firstTranslatedCorrectedSubtitleMs)) |

        ## Speech Counts

        - Latest RMS: \(String(format: "%.4f", report.recognition.latestRMS))
        - Skipped quiet chunks: \(report.recognition.skippedQuietChunks)
        - Low-confidence chunks: \(report.recognition.filteredLowConfidenceChunks)
        - Duplicate chunks: \(report.recognition.filteredDuplicateChunks)
        - Draft chunks: \(report.recognition.candidateChunks)
        - Accepted chunks: \(report.recognition.acceptedChunks)

        ## Translation

        - Attempts: \(translation.attempts)
        - Successes: \(translation.successes)
        - Failures: \(translation.failures)
        - Min latency: \(Self.display(translation.minLatencyMs))
        - Average latency: \(translation.averageLatencyMs.map { "\($0) ms" } ?? "n/a")
        - Max latency: \(Self.display(translation.maxLatencyMs))

        ## Failures

        \(failures)
        """
    }

    private static func display(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "n/a"
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let displayDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct ActiveReliabilitySession {
    let sessionID: UUID
    let startedAt: Date
    let sourceLanguage: String
    let targetLanguage: String
    let asrBackend: String
    let translationBackend: String
    var timings = ReliabilityStartupTimings()
    var recognition = ReliabilityRecognitionMetrics()
    var translation = ReliabilityTranslationMetrics()
    var failures: [ReliabilityFailureRecord] = []

    mutating func setFirstTiming(
        _ keyPath: WritableKeyPath<ReliabilityStartupTimings, Int?>,
        _ value: Int
    ) {
        if timings[keyPath: keyPath] == nil {
            timings[keyPath: keyPath] = value
        }
    }

    func report(endedAt: Date, stopReason: String) -> ReliabilitySessionReport {
        ReliabilitySessionReport(
            schemaVersion: ReliabilitySessionRecorder.schemaVersion,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            stopReason: stopReason,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            asrBackend: asrBackend,
            translationBackend: translationBackend,
            timings: timings,
            recognition: recognition,
            translation: translation,
            failures: failures
        )
    }
}
