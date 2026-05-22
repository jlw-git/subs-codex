import AppKit
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

            Section("Reliability") {
                LabeledContent("Latest report", value: latestReportStatus)
                LabeledContent("Stop reason", value: store.reliabilityRecorder.latestReport?.stopReason ?? "No report yet")
                LabeledContent("First accepted subtitle", value: display(store.reliabilityRecorder.latestReport?.timings.firstAcceptedSubtitleMs))
                LabeledContent("Avg translation latency", value: display(store.reliabilityRecorder.latestReport?.translation.averageLatencyMs))
                LabeledContent("Reports folder") {
                    Text(store.reliabilityRecorder.reportsDirectoryURL.path)
                        .textSelection(.enabled)
                }

                if let latestWriteError = store.reliabilityRecorder.latestWriteError {
                    LabeledContent("Report write error") {
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
                    Label("Open Reports Folder", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }

    private var latestReportStatus: String {
        if store.reliabilityRecorder.latestReport == nil {
            return "No report yet"
        }

        if store.reliabilityRecorder.latestReportFileURLs != nil {
            return "Written locally"
        }

        return "Created in memory"
    }

    private func display(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "n/a"
    }

    private func display(_ value: Double?) -> String {
        value.map { "\($0) ms" } ?? "n/a"
    }
}
