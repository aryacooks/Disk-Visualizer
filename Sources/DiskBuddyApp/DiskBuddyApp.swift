import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // The "Paper" theme is a light design. Pin the appearance so the app
        // doesn't render as inverted paper when the system is in dark mode.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct DiskBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Disk Buddy Checker") {
            MainWindowView()
                .environmentObject(appState)

                // Deliberately no scan on launch. Auto-scanning re-read the
                // disk every time and re-triggered macOS permission prompts for
                // Documents / Downloads / Desktop. AppState restores the last
                // saved snapshot instead (~40 ms), and scanning is user-initiated.
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 840)
    }
}
