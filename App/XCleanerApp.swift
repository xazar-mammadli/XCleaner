import AppKit
import SwiftUI

/// Started by `Launcher`, which runs first.
struct XCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(PreferenceKey.showsMenuBarMonitor) private var showsMenuBarMonitor = false

    var body: some Scene {
        Window("XCleaner", id: "main") {
            // The smallest size at which every page keeps its layout in the wordiest language XCleaner speaks.
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        // Every page starts with its own large title, so the toolbar leaves the room to the tool switcher.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.updates.check(userInitiated: true)
                }
            }
            // XCleaner has no help book, so its help is the project page rather than macOS saying none is available.
            CommandGroup(replacing: .help) {
                Button("XCleaner Help") {
                    NSWorkspace.shared.open(ReleaseSource.help)
                }
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarMonitor) {
            MenuBarPanel()
                .environment(model)
        } label: {
            // The app icon's Broom X, drawn as a template so it takes the menu bar's colour.
            Image(.menuBarIcon)
                .accessibilityLabel(Text(verbatim: "XCleaner"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRelauncher.closePreviousCopy()
        MenuTranslator.shared.start()
    }

    /// With the menu bar monitor on, XCleaner stays in the menu bar after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: PreferenceKey.showsMenuBarMonitor)
    }
}
