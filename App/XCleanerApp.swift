import SwiftUI

@main
struct XCleanerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("XCleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 1060, height: 700)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
