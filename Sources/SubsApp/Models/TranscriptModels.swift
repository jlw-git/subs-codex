import Foundation

enum CaptureState: Equatable {
    case idle
    case starting
    case requestingPermission
    case running
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting"
        case .requestingPermission: "Permission needed"
        case .running: "Capturing"
        case .failed: "Action needed"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }

        return nil
    }
}

struct TranscriptSegment: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let speaker: String
    let sourceText: String
    let translatedText: String
    let isFinal: Bool
}

struct TranslationJob: Identifiable, Equatable {
    let id = UUID()
    let sourceText: String
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language
    let isFinal: Bool
}
