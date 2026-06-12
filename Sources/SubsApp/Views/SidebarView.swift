import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        List {
            Section("Session") {
                SidebarStatusRow(title: store.statusTitle, detail: "\(store.sourceLanguage) to \(store.targetLanguage)", systemImage: stateIcon, tint: stateTint)
                SidebarStatusRow(title: "Local only", detail: "Cloud off", systemImage: "network.slash", tint: .green)
            }

            Section("Languages") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Source")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Source", selection: $store.sourceLanguage) {
                        Text("Thai").tag("Thai")
                        Text("Japanese").tag("Japanese")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(store.targetLanguage)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Subs")
    }

    private var stateIcon: String {
        switch store.capture.state {
        case .idle: "pause.circle"
        case .starting: "hourglass"
        case .requestingPermission: "lock.open"
        case .running: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var stateTint: Color {
        if store.isRunning { return .green }
        if store.isStarting { return .blue }
        if store.capture.state.failureMessage != nil || store.speech.state.failureMessage != nil {
            return .red
        }
        return .secondary
    }
}

private struct SidebarStatusRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }
}
