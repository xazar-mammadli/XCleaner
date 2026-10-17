import AppKit
import SwiftUI

/// Started by `Launcher`, which runs first.
struct XCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(PreferenceKey.showsMenuBarMonitor) private var showsMenuBarMonitor = false

    var body: some Scene {
        Window("XCleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 1060, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.updates.check(userInitiated: true)
                }
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarMonitor) {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar monitor on, XCleaner stays in the menu bar after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: PreferenceKey.showsMenuBarMonitor)
    }
}
