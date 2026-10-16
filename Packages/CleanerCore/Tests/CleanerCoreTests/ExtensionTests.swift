import Foundation
import Testing
@testable import CleanerCore

@Suite("Extensions")
struct ExtensionTests {
    @Test func findsAddOnsForTheUserAndForEveryone() throws {
        let sandbox = try Sandbox()
        let home = try sandbox.directory("Home")
        let system = try sandbox.directory("SystemLibrary")
        try sandbox.plist("Home/Library/PreferencePanes/Foo.prefPane/Contents/Info.plist", [
            "CFBundleName": "Foo Pane", "CFBundleShortVersionString": "1.2",
        ])
        try sandbox.file("Home/Library/PreferencePanes/Foo.prefPane/Contents/MacOS/Foo")
        try sandbox.file("Home/Library/Services/Do Something.workflow/Contents/document.wflow")
        try sandbox.file("Home/Library/Spotlight/Assets/cache.db")
        try sandbox.file("Home/Library/QuickLook/notes.txt")
        try sandbox.file("SystemLibrary/Audio/Plug-Ins/HAL/Loopback.driver/Contents/MacOS/Loopback")

        let found = ExtensionScanner(home: home, systemLibrary: system).extensions()
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Foo Pane", "Do Something", "Loopback"])
        #expect(byName["Foo Pane"]?.kind == .preferencePane)
        #expect(byName["Foo Pane"]?.version == "1.2")
        #expect(byName["Foo Pane"]?.isSystemWide == false)
        #expect(byName["Do Something"]?.kind == .service)
        #expect(byName["Loopback"]?.kind == .audioPlugIn)
        #expect(byName["Loopback"]?.isSystemWide == true)
        #expect((byName["Loopback"]?.size ?? 0) > 0)
    }

    @Test func readsChromiumExtensionsWithTheirOwnNames() throws {
        let sandbox = try Sandbox()
        let chrome = "Library/Application Support/Google/Chrome"
        let folder = "\(chrome)/Default/Extensions/abcdefgh"
        try sandbox.directory("\(folder)/1.9_0")
        try writeJSON(sandbox, "\(folder)/1.10_0/manifest.json", [
            "name": "__MSG_appName__", "default_locale": "en", "version": "1.10",
            "icons": ["16": "icon16.png", "128": "icon128.png"],
        ])
        try writeJSON(sandbox, "\(folder)/1.10_0/_locales/en/messages.json", ["APPNAME": ["message": "Tab Saver"]])
        try writeJSON(sandbox, "\(chrome)/Local State", ["profile": ["info_cache": ["Default": ["name": "Work"]]]])

        let found = BrowserExtensionScanner(home: sandbox.root).extensions().filter { $0.browser.name == "Google Chrome" }
        let tabSaver = try #require(found.first)
        #expect(found.count == 1)
        #expect(tabSaver.name == "Tab Saver")
        #expect(tabSaver.version == "1.10")
        #expect(tabSaver.profile == "Work")
        #expect(tabSaver.icon?.lastPathComponent == "icon128.png")
    }

    @Test func readsFirefoxExtensionsTheUserInstalled() throws {
        let sandbox = try Sandbox()
        try writeJSON(sandbox, "Library/Application Support/Firefox/Profiles/x1y2z3.default-release/extensions.json", [
            "addons": [
                ["id": "ublock@example", "type": "extension", "location": "app-profile", "version": "1.5",
                 "defaultLocale": ["name": "uBlock Origin"]],
                ["id": "builtin@mozilla", "type": "extension", "location": "app-builtin", "defaultLocale": ["name": "Built In"]],
                ["id": "theme@example", "type": "theme", "location": "app-profile", "defaultLocale": ["name": "Dark"]],
            ],
        ])
        let found = BrowserExtensionScanner(home: sandbox.root).extensions().filter { $0.browser.name == "Firefox" }
        #expect(found.map(\.name) == ["uBlock Origin"])
        #expect(found.first?.profile == "default-release")
    }

    @Test func readsPluginKitOutput() {
        let output = """
                 com.example.blocker(2.1)\t3E3A1C00-0000-4000-8000-000000000000\t2026-06-10 16:00:47 +0000\t/Applications/Blocker.app/Contents/PlugIns/Blocker Extension.appex
            +    com.example.other(1.0)\tUUID\tdate\t/Applications/Other.app/Contents/PlugIns/Other.appex
             (2 plug-ins)
            """
        let found = BrowserExtensionScanner.parsePluginKit(output)
        #expect(found.map(\.identifier) == ["com.example.blocker", "com.example.other"])
        #expect(found.first?.version == "2.1")
        #expect(found.first?.profile == "Blocker")
    }

    private func writeJSON(_ sandbox: Sandbox, _ relative: String, _ object: Any) throws {
        let url = sandbox.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
