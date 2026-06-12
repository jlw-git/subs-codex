import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        Form {
            Section("Readiness") {
                SettingsStatusRow(title: store.readinessSummary.title, value: store.readinessSummary.detail, systemImage: store.readinessSummary.systemImage, tint: readinessTint)
                SettingsStatusRow(title: "Local only", value: "On", systemImage: "network.slash", tint: .green)
                SettingsStatusRow(title: "System audio", value: captureStatus, systemImage: "speaker.wave.2", tint: captureTint)
                SettingsStatusRow(title: "Speech model", value: store.speechBackend.detail, systemImage: "waveform", tint: speechTint)
                SettingsStatusRow(title: "Translation", value: store.translation.translationStatus.title, systemImage: "character.book.closed", tint: translationTint)
                SettingsStatusRow(title: "Thai model", value: store.translation.thaiModelStatus, systemImage: "shippingbox", tint: modelTint(store.translation.thaiModelStatus))
                SettingsStatusRow(title: "Japanese model", value: store.translation.japaneseModelStatus, systemImage: "shippingbox", tint: modelTint(store.translation.japaneseModelStatus))

                Button {
                    Task { await store.checkReadiness() }
                } label: {
                    Label("Check Readiness", systemImage: "checkmark.shield")
                }
                .disabled(store.isReadinessCheckDisabled)
            }

            Section("Privacy") {
                LabeledContent("Network", value: "Off")
                LabeledContent("Meeting data", value: "On this Mac")
                LabeledContent("Storage", value: "Memory only")
                LabeledContent("Capture", value: "System audio")
            }

            Section("Models") {
                Picker("Speech", selection: $store.speechBackend) {
                    ForEach(SpeechRecognitionBackendKind.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }

                LabeledContent("Speech", value: store.speech.activeBackendName)
                LabeledContent("Translation", value: store.translation.activeBackendName)
                LabeledContent("Status", value: store.translation.translationStatus.title)
                PathValue(title: "Python", path: store.translation.runtimePath)

                if let latestPreflightError = store.translation.latestPreflightError {
                    LabeledContent("Setup error") {
                        Text(latestPreflightError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Reliability") {
                LabeledContent("Report", value: latestReportStatus)
                LabeledContent("Stop reason", value: store.reliabilityRecorder.latestReport?.stopReason ?? "No report yet")
                LabeledContent("First subtitle", value: display(store.reliabilityRecorder.latestReport?.timings.firstAcceptedSubtitleMs))
                LabeledContent("Avg translation", value: display(store.reliabilityRecorder.latestReport?.translation.averageLatencyMs))
                PathValue(title: "Folder", path: store.reliabilityRecorder.reportsDirectoryURL.path)

                if let latestWriteError = store.reliabilityRecorder.latestWriteError {
                    LabeledContent("Save error") {
                        Text(latestWriteError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Button {
                    try? FileManager.default.createDirectory(
                        at: store.reliabilityRecorder.reportsDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(store.reliabilityRecorder.reportsDirectoryURL)
                } label: {
                    Label("Open Reports", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }

    private var captureStatus: String {
        switch store.capture.state {
        case .idle: "Not checked"
        case .starting: "Starting"
        case .requestingPermission: "Permission needed"
        case .running: "Capturing"
        case .failed: "Action needed"
        }
    }

    private var captureTint: Color {
        switch store.capture.state {
        case .running: .green
        case .failed: .red
        case .requestingPermission, .starting: .blue
        case .idle: .secondary
        }
    }

    private var speechTint: Color {
        switch store.speech.state {
        case .running: .green
        case .failed: .red
        case .requestingPermission, .starting: .blue
        case .idle: .secondary
        }
    }

    private var translationTint: Color {
        switch store.translation.translationStatus {
        case .ready: .green
        case .failed: .red
        case .checking: .blue
        case .notChecked: .secondary
        }
    }

    private var readinessTint: Color {
        switch store.readinessSummary.tone {
        case .ready: .green
        case .checking: .blue
        case .critical: .red
        case .neutral: .secondary
        }
    }

    private var latestReportStatus: String {
        if store.reliabilityRecorder.latestReport == nil {
            return "None"
        }

        if store.reliabilityRecorder.latestReportFileURLs != nil {
            return "Saved"
        }

        return "In memory"
    }

    private func display(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "n/a"
    }

    private func display(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "n/a"
    }

    private func modelTint(_ status: String) -> Color {
        status == "Installed" ? .green : .red
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } label: {
            Label(title, systemImage: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
    }
}

private struct PathValue: View {
    let title: String
    let path: String

    var body: some View {
        LabeledContent(title) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
