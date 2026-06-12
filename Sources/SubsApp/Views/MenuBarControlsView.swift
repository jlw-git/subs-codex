import AppKit
import SwiftUI

struct MenuBarControlsView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    let openTranscript: () -> Void
    let openOverlay: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            StatusHeaderView()

            Divider()

            Button {
                Task { await store.checkReadiness() }
            } label: {
                Label("Check Readiness", systemImage: "checkmark.shield")
            }
            .disabled(store.isReadinessCheckDisabled)

            Button {
                Task { await store.toggleCapture() }
            } label: {
                Label(store.isRunning ? "Stop" : store.primaryActionTitle, systemImage: store.primaryActionSystemImage)
            }
            .disabled(store.isStarting)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button {
                openOverlay()
            } label: {
                Label("Subtitles", systemImage: "rectangle.on.rectangle")
            }

            Button {
                openTranscript()
            } label: {
                Label("Transcript", systemImage: "text.alignleft")
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
        .frame(width: 300)
    }
}

private struct StatusHeaderView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.readinessSummary.systemImage)
                .font(.title2)
                .foregroundStyle(readinessColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.readinessSummary.title)
                    .font(.headline)

                Text("\(store.readinessSummary.detail) | Local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var readinessColor: Color {
        switch store.readinessSummary.tone {
        case .ready: .green
        case .checking: .blue
        case .critical: .red
        case .neutral: .secondary
        }
    }
}
