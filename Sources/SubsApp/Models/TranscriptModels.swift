import Foundation

enum CaptureState: Equatable {
    case idle
    case requestingPermission
    case running
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Idle"
        case .requestingPermission: "Requesting Permission"
        case .running: "Capturing Locally"
        case .failed: "Needs Attention"
        }
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
