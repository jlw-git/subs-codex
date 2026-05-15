import AppKit
import SwiftUI

@main
struct SubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionStore = MeetingSessionStore()

    var body: some Scene {
        WindowGroup("Subs", id: "main") {
            ContentView()
                .environmentObject(sessionStore)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(sessionStore.isRunning ? "Stop Capturing" : "Start Capturing") {
                    Task { await sessionStore.toggleCapture() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
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
