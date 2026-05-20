import Foundation

enum SpeechRecognitionBackendKind: String, CaseIterable, Identifiable {
    case localWhisper
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localWhisper: "Local Whisper"
        case .appleSpeech: "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .localWhisper: "Bundled local ASR model"
        case .appleSpeech: "Apple on-device Speech"
        }
    }
}
