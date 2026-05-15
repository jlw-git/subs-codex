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
                LabeledContent("Transcription", value: "Apple on-device Speech")
                LabeledContent("Translation", value: "Apple on-device Translation, macOS 15+")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }
}
