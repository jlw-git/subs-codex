import AppKit
import SwiftUI

@main
struct SubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionStore = MeetingSessionStore()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup("Subs", id: "main") {
            ContentView()
                .environmentObject(sessionStore)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(sessionStore.isRunning ? "Stop" : "Start") {
                    Task { await sessionStore.toggleCapture() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Subtitles", id: "overlay") {
            SubtitleOverlayView()
                .environmentObject(sessionStore)
                .frame(width: 760, height: 190)
        }

        Window("Transcript", id: "transcript") {
            TranscriptMemoryView()
                .environmentObject(sessionStore)
                .frame(width: 420, height: 560)
        }

        MenuBarExtra {
            MenuBarControlsView(
                openTranscript: { openWindow(id: "transcript") },
                openOverlay: { openWindow(id: "overlay") },
                openSettings: { openSettings() }
            )
            .environmentObject(sessionStore)
        } label: {
            Label("Subs", systemImage: sessionStore.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }

        Settings {
            SettingsView()
                .environmentObject(sessionStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
