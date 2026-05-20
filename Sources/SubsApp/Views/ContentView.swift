import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            HStack(spacing: 0) {
                LiveSubtitlesView()
                    .frame(minWidth: 540)

                Divider()

                TranscriptMemoryView()
                    .frame(width: 360)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.toggleCapture() }
                } label: {
                    Label(store.primaryActionTitle, systemImage: store.primaryActionSystemImage)
                }
                .disabled(store.isStarting)
                .help(store.isRunning ? "Stop local capture" : "Start local capture")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear local transcript memory")
            }
        }
    }
}
