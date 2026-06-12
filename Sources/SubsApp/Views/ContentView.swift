import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            LiveSubtitlesView()
                .frame(minWidth: 540)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.toggleCapture() }
                } label: {
                    Label(store.primaryActionTitle, systemImage: store.primaryActionSystemImage)
                }
                .disabled(store.isStarting)
                .help(store.isRunning ? "Stop capture" : "Start capture")
            }
        }
    }
}
