import Foundation
@testable import SubsApp
import Testing

@MainActor
@Suite
struct ReliabilitySessionRecorderTests {
    @Test
    func testReportDoesNotContainRecognizedOrTranslatedText() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var now = Date(timeIntervalSince1970: 1000)
        let recorder = ReliabilitySessionRecorder(
            reportsDirectoryURL: temporaryDirectory,
            dateProvider: { now },
            idProvider: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )

        recorder.start(
            sourceLanguage: "Thai",
            targetLanguage: "English",
            asrBackend: "Local Whisper",
            translationBackend: "OPUS-MT local runtime"
        )
        now = now.addingTimeInterval(1)
        recorder.markRecognition(.accepted, metrics: RecognitionDebugMetrics(latestRMS: 0.01, skippedQuietChunks: 1, filteredLowConfidenceChunks: 2, filteredDuplicateChunks: 3, candidateChunks: 4, acceptedChunks: 5))
        recorder.recordTranslationAttempt()
        now = now.addingTimeInterval(0.4)
        recorder.recordTranslationSuccess(latencyMs: 400)

        let report = try #require(recorder.finalize(stopReason: "stopped_by_user"))
        let urls = try #require(recorder.latestReportFileURLs)
        let json = try String(contentsOf: urls.json)
        let markdown = try String(contentsOf: urls.markdown)

        #expect(report.recognition.acceptedChunks == 5)
        #expect(!json.contains("วันนี้เราจะเริ่มประชุม"))
        #expect(!json.contains("Today we will start the meeting"))
        #expect(!markdown.contains("วันนี้เราจะเริ่มประชุม"))
        #expect(!markdown.contains("Today we will start the meeting"))
    }

    @Test
    func testTimingAndTranslationAggregation() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var now = Date(timeIntervalSince1970: 2000)
        let recorder = ReliabilitySessionRecorder(
            reportsDirectoryURL: temporaryDirectory,
            dateProvider: { now },
            idProvider: { UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")! }
        )

        recorder.start(
            sourceLanguage: "Japanese",
            targetLanguage: "English",
            asrBackend: "Local Whisper",
            translationBackend: "OPUS-MT local runtime"
        )
        now = now.addingTimeInterval(0.2)
        recorder.markASRReady()
        now = now.addingTimeInterval(0.3)
        recorder.markCaptureRunning()
        now = now.addingTimeInterval(0.4)
        recorder.markFirstAudioBuffer()
        now = now.addingTimeInterval(0.1)
        recorder.markRecognition(.candidate, metrics: RecognitionDebugMetrics(candidateChunks: 1))
        now = now.addingTimeInterval(0.2)
        recorder.markRecognition(.accepted, metrics: RecognitionDebugMetrics(candidateChunks: 1, acceptedChunks: 1))

        recorder.recordTranslationAttempt()
        recorder.recordTranslationSuccess(latencyMs: 300)
        recorder.recordTranslationAttempt()
        recorder.recordTranslationFailure(latencyMs: 900, message: "Local translation unavailable")

        let report = try #require(recorder.finalize(stopReason: "stopped_by_user"))

        #expect(report.timings.asrReadyMs == 200)
        #expect(report.timings.captureRunningMs == 500)
        #expect(report.timings.firstAudioBufferMs == 900)
        #expect(report.timings.firstCandidateSubtitleMs == 1000)
        #expect(report.timings.firstAcceptedSubtitleMs == 1200)
        #expect(report.translation.attempts == 2)
        #expect(report.translation.successes == 1)
        #expect(report.translation.failures == 1)
        #expect(report.translation.minLatencyMs == 300)
        #expect(report.translation.averageLatencyMs == 600.0)
        #expect(report.translation.maxLatencyMs == 900)
    }

    @Test
    func testFailureFinalizationWritesStopReasonAndFailureStage() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var now = Date(timeIntervalSince1970: 3000)
        let recorder = ReliabilitySessionRecorder(
            reportsDirectoryURL: temporaryDirectory,
            dateProvider: { now },
            idProvider: { UUID(uuidString: "99999999-8888-7777-6666-555555555555")! }
        )

        recorder.start(
            sourceLanguage: "Thai",
            targetLanguage: "English",
            asrBackend: "Local Whisper",
            translationBackend: "OPUS-MT local runtime"
        )
        now = now.addingTimeInterval(0.25)
        recorder.recordFailure(stage: "capture_start", message: "Screen & System Audio Recording permission is required.")

        let report = try #require(recorder.finalize(stopReason: "capture_failed"))
        let urls = try #require(recorder.latestReportFileURLs)
        let decoded = try JSONDecoder.reliabilityReportDecoder.decode(
            ReliabilitySessionReport.self,
            from: Data(contentsOf: urls.json)
        )

        #expect(report.stopReason == "capture_failed")
        #expect(decoded.stopReason == "capture_failed")
        #expect(decoded.failures.first?.stage == "capture_start")
        #expect(decoded.failures.first?.message == "Screen & System Audio Recording permission is required.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubsAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        return temporaryDirectory
    }
}

private extension RecognitionDebugMetrics {
    init(
        latestRMS: Double = 0,
        skippedQuietChunks: Int = 0,
        filteredLowConfidenceChunks: Int = 0,
        filteredDuplicateChunks: Int = 0,
        candidateChunks: Int = 0,
        acceptedChunks: Int = 0
    ) {
        self.init()
        self.latestRMS = latestRMS
        self.skippedQuietChunks = skippedQuietChunks
        self.filteredLowConfidenceChunks = filteredLowConfidenceChunks
        self.filteredDuplicateChunks = filteredDuplicateChunks
        self.candidateChunks = candidateChunks
        self.acceptedChunks = acceptedChunks
    }
}

private extension JSONDecoder {
    static var reliabilityReportDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
