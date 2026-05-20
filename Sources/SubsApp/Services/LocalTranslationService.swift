import Foundation

@MainActor
final class LocalTranslationService: ObservableObject {
    @Published private(set) var activeBackendName = "OPUS-MT local runtime"
    @Published private(set) var translationStatus = TranslationRuntimeStatus.notChecked
    @Published private(set) var latestPreflightError: String?

    private let backend = OPUSMTTranslationBackend()

    var runtimePath: String {
        backend.runtimePath
    }

    var thaiModelStatus: String {
        backend.modelStatus(for: "th-en")
    }

    var japaneseModelStatus: String {
        backend.modelStatus(for: "ja-en")
    }

    func prepare() async throws {
        activeBackendName = backend.displayName
        translationStatus = .checking
        latestPreflightError = nil

        do {
            try LocalOnlyPolicy.validate(backend.declaration)
            try await backend.prepare()
            translationStatus = .ready
        } catch {
            let message = error.localizedDescription
            latestPreflightError = message
            translationStatus = .failed(message)
            throw error
        }
    }

    func translate(_ job: TranslationJob) async throws -> String {
        activeBackendName = backend.displayName
        try LocalOnlyPolicy.validate(backend.declaration)
        return try await backend.translate(job)
    }
}

enum TranslationRuntimeStatus: Equatable {
    case notChecked
    case checking
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .notChecked: "Not Checked"
        case .checking: "Checking"
        case .ready: "Ready"
        case .failed: "Needs Attention"
        }
    }
}

private protocol TranslationBackend {
    var displayName: String { get }
    var declaration: LocalOnlyBackendDeclaration { get }

    func prepare() async throws
    func translate(_ job: TranslationJob) async throws -> String
}

@MainActor
private final class OPUSMTTranslationBackend: TranslationBackend {
    let displayName = "OPUS-MT local runtime"
    let declaration = LocalOnlyBackendDeclaration(
        name: "OPUS-MT local translation runtime",
        purpose: "translation",
        location: .onDevice,
        allowsCloudFallback: false
    )

    private var worker: OPUSMTWorker?

    var runtimePath: String {
        Self.pythonExecutablePath()
    }

    func prepare() async throws {
        try validateLocalRuntime()
        try await workerInstance().preflight(requests: [
            Self.workerRequest(
                command: .translate,
                sourceText: "สวัสดี",
                sourceLanguageCode: "th",
                targetLanguageCode: "en",
                modelPath: Self.modelPath(for: "th-en")
            ),
            Self.workerRequest(
                command: .translate,
                sourceText: "こんにちは",
                sourceLanguageCode: "ja",
                targetLanguageCode: "en",
                modelPath: Self.modelPath(for: "ja-en")
            )
        ])
    }

    func translate(_ job: TranslationJob) async throws -> String {
        let sourceLanguageCode = Self.languageCode(for: job.sourceLanguage)
        let targetLanguageCode = Self.languageCode(for: job.targetLanguage)
        let languagePair = "\(sourceLanguageCode)-\(targetLanguageCode)"

        guard ["th-en", "ja-en"].contains(languagePair) else {
            throw LocalTranslationError.unsupportedLanguagePair(languagePair)
        }

        let response = try await workerInstance().send(Self.workerRequest(
            command: .translate,
            sourceText: job.sourceText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            modelPath: Self.modelPath(for: languagePair)
        ))

        guard response.ok else {
            throw LocalTranslationError.runtimeFailed(response.error ?? "OPUS-MT worker failed without an error message.")
        }

        return (response.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func modelStatus(for languagePair: String) -> String {
        let path = Self.modelPath(for: languagePair)
        guard !path.isEmpty else { return "Missing path" }
        return FileManager.default.fileExists(atPath: path) ? "Installed" : "Missing"
    }

    private func workerInstance() throws -> OPUSMTWorker {
        if let worker {
            return worker
        }

        guard let scriptURL = Bundle.module.url(forResource: "opus_mt_translate", withExtension: "py") else {
            throw LocalTranslationError.runnerMissing
        }

        let worker = OPUSMTWorker(
            executablePath: Self.pythonExecutablePath(),
            scriptPath: scriptURL.path
        )
        self.worker = worker
        return worker
    }

    private func validateLocalRuntime() throws {
        let pythonPath = Self.pythonExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw LocalTranslationError.runtimeMissing(pythonPath)
        }

        for languagePair in ["th-en", "ja-en"] {
            let modelPath = Self.modelPath(for: languagePair)
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw LocalTranslationError.modelMissing(languagePair: languagePair, path: modelPath)
            }
        }
    }

    private static func workerRequest(
        command: OPUSMTWorkerCommand,
        sourceText: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        modelPath: String
    ) -> OPUSMTWorkerRequest {
        OPUSMTWorkerRequest(
            id: UUID().uuidString,
            command: command,
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            modelPath: modelPath
        )
    }

    private static func languageCode(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier

        if identifier.hasPrefix("ja") { return "ja" }
        if identifier.hasPrefix("th") { return "th" }
        return "en"
    }

    private static func modelPath(for languagePair: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        let pairSpecificKey = "SUBS_OPUS_MT_MODEL_\(languagePair.replacingOccurrences(of: "-", with: "_").uppercased())"

        if let modelPath = environment[pairSpecificKey], !modelPath.isEmpty {
            return expandingTilde(in: modelPath)
        }

        if let modelsRoot = environment["SUBS_OPUS_MT_MODELS_DIR"], !modelsRoot.isEmpty {
            return URL(fileURLWithPath: expandingTilde(in: modelsRoot), isDirectory: true)
                .appendingPathComponent(languagePair, isDirectory: true)
                .path
        }

        return applicationSupportURL()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("opus-mt", isDirectory: true)
            .appendingPathComponent(languagePair, isDirectory: true)
            .path
    }

    private static func pythonExecutablePath() -> String {
        let configuredPath = ProcessInfo.processInfo.environment["SUBS_PYTHON"] ?? ""
        if !configuredPath.isEmpty {
            return expandingTilde(in: configuredPath)
        }

        return applicationSupportURL()
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("opus", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
            .path
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

private enum OPUSMTWorkerCommand: String, Codable {
    case translate
}

private struct OPUSMTWorkerRequest: Codable {
    let id: String
    let command: OPUSMTWorkerCommand
    let sourceText: String
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let modelPath: String
}

private struct OPUSMTWorkerResponse: Codable {
    let id: String
    let ok: Bool
    let translatedText: String?
    let error: String?
}

private final class OPUSMTWorker: @unchecked Sendable {
    private let executablePath: String
    private let scriptPath: String
    private let queue = DispatchQueue(label: "com.jlwong.Subs.OPUSMTWorker")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?

    init(executablePath: String, scriptPath: String) {
        self.executablePath = executablePath
        self.scriptPath = scriptPath
    }

    func preflight(requests: [OPUSMTWorkerRequest]) async throws {
        for request in requests {
            let response = try await send(request)
            guard response.ok, !(response.translatedText ?? "").isEmpty else {
                throw LocalTranslationError.runtimeFailed(response.error ?? "OPUS-MT preflight returned an empty translation.")
            }
        }
    }

    func send(_ request: OPUSMTWorkerRequest) async throws -> OPUSMTWorkerResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startIfNeeded()

                    let requestData = try JSONEncoder().encode(request)
                    guard var requestLine = String(data: requestData, encoding: .utf8) else {
                        throw LocalTranslationError.runtimeFailed("Could not encode OPUS-MT request.")
                    }
                    requestLine.append("\n")

                    guard let inputHandle = self.inputHandle,
                          let outputHandle = self.outputHandle else {
                        throw LocalTranslationError.runtimeFailed("OPUS-MT worker pipes are unavailable.")
                    }

                    try inputHandle.write(contentsOf: Data(requestLine.utf8))
                    guard let lineData = try outputHandle.readLineData() else {
                        let errorOutput = self.readWorkerError()
                        self.stop()
                        throw LocalTranslationError.runtimeFailed(errorOutput.isEmpty ? "OPUS-MT worker exited without a response." : errorOutput)
                    }

                    let response = try JSONDecoder().decode(OPUSMTWorkerResponse.self, from: lineData)
                    guard response.id == request.id else {
                        throw LocalTranslationError.runtimeFailed("OPUS-MT worker response id did not match the request.")
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
        process.executableURL = URL(fileURLWithPath: executablePath)
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

enum LocalTranslationError: LocalizedError, Equatable {
    case runnerMissing
    case runtimeMissing(String)
    case modelMissing(languagePair: String, path: String)
    case unsupportedLanguagePair(String)
    case runtimeFailed(String)

    var errorDescription: String? {
        switch self {
        case .runnerMissing:
            "The bundled OPUS-MT translation runner is missing from the app resources."
        case .runtimeMissing(let path):
            "The local OPUS-MT Python runtime was not found at \(path). Run script/setup_opus_mt.sh and retry."
        case .modelMissing(let languagePair, let path):
            "The local OPUS-MT \(languagePair) model folder was not found at \(path). Run script/setup_opus_mt.sh and retry."
        case .unsupportedLanguagePair(let languagePair):
            "No local translation model is configured for \(languagePair). Subs currently supports th-en and ja-en."
        case .runtimeFailed(let message):
            message
        }
    }
}
