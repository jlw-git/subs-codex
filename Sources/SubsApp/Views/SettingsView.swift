import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        Form {
            Section("Privacy") {
                LabeledContent("Network use", value: "Disabled by design")
                LabeledContent("Storage", value: "In-memory prototype")
                LabeledContent("Capture source", value: "macOS system audio")
                LabeledContent("Summary feature", value: "Removed")
            }

            Section("Model Runtime") {
                Picker("Transcription", selection: $store.speechBackend) {
                    ForEach(SpeechRecognitionBackendKind.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }

                LabeledContent("Active ASR", value: store.speech.activeBackendName)
                LabeledContent("Translation", value: store.translation.activeBackendName)
                LabeledContent("Translation status", value: store.translation.translationStatus.title)
                LabeledContent("Runtime", value: store.translation.runtimePath)
                LabeledContent("Thai model", value: store.translation.thaiModelStatus)
                LabeledContent("Japanese model", value: store.translation.japaneseModelStatus)

                if let latestPreflightError = store.translation.latestPreflightError {
                    LabeledContent("Preflight error") {
                        Text(latestPreflightError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }
}
