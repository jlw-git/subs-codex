import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        List {
            Section("Session") {
                Label(store.capture.state.title, systemImage: stateIcon)
                Label("No cloud transport", systemImage: "network.slash")
                Label("\(store.segments.count) transcript lines", systemImage: "text.alignleft")
            }

            Section("Languages") {
                Picker("Source", selection: $store.sourceLanguage) {
                    Text("Thai").tag("Thai")
                    Text("Japanese").tag("Japanese")
                }

                Picker("Target", selection: $store.targetLanguage) {
                    Text("English").tag("English")
                }

                Picker("ASR", selection: $store.speechBackend) {
                    ForEach(SpeechRecognitionBackendKind.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Subs")
    }

    private var stateIcon: String {
        switch store.capture.state {
        case .idle: "pause.circle"
        case .requestingPermission: "lock.open"
        case .running: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }
}
