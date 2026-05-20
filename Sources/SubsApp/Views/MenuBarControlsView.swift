import AppKit
import SwiftUI

struct MenuBarControlsView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    let openTranscript: () -> Void
    let openOverlay: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeaderView()

            Divider()

            Button {
                Task { await store.toggleCapture() }
            } label: {
                Label(store.isRunning ? "Stop Capture" : "Start Capture", systemImage: store.isRunning ? "stop.fill" : "play.fill")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button {
                openOverlay()
            } label: {
                Label("Show Subtitles", systemImage: "rectangle.on.rectangle")
            }

            Button {
                openTranscript()
            } label: {
                Label("Open Transcript", systemImage: "text.alignleft")
            }

            Divider()

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

            Divider()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Subs", systemImage: "power")
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct StatusHeaderView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.isRunning ? "waveform.circle.fill" : "lock.shield")
                .font(.title2)
                .foregroundStyle(store.isRunning ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.capture.state.title)
                    .font(.headline)

                Text("\(store.sourceLanguage) -> \(store.targetLanguage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
