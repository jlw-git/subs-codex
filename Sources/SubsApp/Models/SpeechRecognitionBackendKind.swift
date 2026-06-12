import Foundation

enum SpeechRecognitionBackendKind: String, CaseIterable, Hashable, Identifiable {
    case liveFastWhisperCpp
    case localWhisper
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveFastWhisperCpp: "Live Fast"
        case .localWhisper: "Accurate"
        case .appleSpeech: "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .liveFastWhisperCpp: "whisper.cpp large-v3-turbo"
        case .localWhisper: "WhisperKit medium"
        case .appleSpeech: "Apple on-device"
        }
    }

    var declaration: LocalOnlyBackendDeclaration {
        switch self {
        case .liveFastWhisperCpp:
            LocalOnlyBackendDeclaration(
                name: "whisper.cpp local ASR",
                purpose: "speech-to-text",
                location: .onDevice,
                allowsCloudFallback: false
            )
        case .localWhisper:
            LocalOnlyBackendDeclaration(
                name: "WhisperKit local ASR",
                purpose: "speech-to-text",
                location: .onDevice,
                allowsCloudFallback: false
            )
        case .appleSpeech:
            LocalOnlyBackendDeclaration(
                name: "Apple Speech on-device recognition",
                purpose: "speech-to-text",
                location: .onDevice,
                allowsCloudFallback: false
            )
        }
    }
}
