import Foundation
import Testing
@testable import CleanerCore

@Suite("BrowserData")
struct BrowserDataTests {
    @Test func findsChromiumDataAndNothingElse() throws {
        let sandbox = try Sandbox()
        let chrome = "Library/Application Support/Google/Chrome"
        for file in [
            "Default/History", "Default/History-journal", "Default/Cookies", "Default/Network/Cookies", "Default/GPUCache/data_0",
            "Profile 1/History",
            // Never part of browser data.
            "Default/Bookmarks", "Default/Login Data", "Default/Web Data", "Default/Sessions/Session_1", "Default/Preferences",
        ] {
            try sandbox.file("\(chrome)/\(file)")
        }
        try sandbox.file("Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 4_096)

        let items = BrowserDataScanner(home: sandbox.root).scan(hasFullDiskAccess: false).items.filter { $0.browser == .chrome }
        func names(_ kind: BrowserDataItem.Kind) -> Set<String> {
            Set(items.first { $0.kind == kind }?.targets.map { relative($0.url, in: sandbox) } ?? [])
        }
        #expect(names(.history) == ["\(chrome)/Default/History", "\(chrome)/Default/History-journal", "\(chrome)/Profile 1/History"])
        #expect(names(.cookies) == ["\(chrome)/Default/Cookies", "\(chrome)/Default/Network/Cookies"])
        #expect(names(.cache) == ["\(chrome)/Default/GPUCache", "Library/Caches/Google/Chrome/Default"])

        let everything = items.flatMap(\.targets).map { $0.url.lastPathComponent }
        for kept in ["Bookmarks", "Login Data", "Web Data", "Sessions", "Preferences"] {
            #expect(!everything.contains(kept))
        }
        // Every target stays strictly inside its root.
        #expect(items.flatMap(\.targets).allSatisfy {
            $0.url.path(percentEncoded: false).hasPrefix($0.root.path(percentEncoded: false) + "/")
        })
    }

    @Test func leavesFirefoxHistoryWithItsBookmarks() throws {
        let sandbox = try Sandbox()
        let profile = "Library/Application Support/Firefox/Profiles/a1b2.default-release"
        try sandbox.file("\(profile)/cookies.sqlite")
        try sandbox.file("\(profile)/places.sqlite")
        try sandbox.file("Library/Caches/Firefox/Profiles/a1b2.default-release/cache2/entries/x")

        let items = BrowserDataScanner(home: sandbox.root).scan(hasFullDiskAccess: false).items.filter { $0.browser == .firefox }
        #expect(Set(items.map(\.kind)) == [.cache, .cookies])
        #expect(!items.flatMap(\.targets).contains { $0.url.lastPathComponent == "places.sqlite" })
    }

    @Test func looksAtSafariOnlyWithFullDiskAccess() throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Safari/History.db")
        try sandbox.file("Library/Safari/Bookmarks.plist")
        try sandbox.file("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        let scanner = BrowserDataScanner(home: sandbox.root)

        let without = scanner.scan(hasFullDiskAccess: false)
        #expect(!without.items.contains { $0.browser == .safari })
        #expect(!without.issues.isEmpty)

        let with = scanner.scan(hasFullDiskAccess: true).items.filter { $0.browser == .safari }
        #expect(Set(with.map(\.kind)) == [.cache, .history, .cookies])
        #expect(Set(with.filter { !$0.isEmpty }.map(\.kind)) == [.history, .cookies])
        #expect(!with.flatMap(\.targets).contains { $0.url.lastPathComponent == "Bookmarks.plist" })
    }

    @Test func keepsEveryKindListedOnceCleared() throws {
        let sandbox = try Sandbox()
        // Just after clearing: the profile is there, with nothing but its history left.
        try sandbox.file("Library/Application Support/Google/Chrome/Default/History", bytes: 4_096)
        let items = BrowserDataScanner(home: sandbox.root).scan(hasFullDiskAccess: false).items.filter { $0.browser == .chrome }
        #expect(items.map(\.kind) == [.cache, .history, .cookies])
        #expect(items.filter(\.isEmpty).map(\.kind) == [.cache, .cookies])
        // A browser that isn't installed doesn't show up at all.
        #expect(!BrowserDataScanner(home: sandbox.root).scan(hasFullDiskAccess: false).items.contains { $0.browser == .edge })
    }

    private func relative(_ url: URL, in sandbox: Sandbox) -> String {
        String(url.path(percentEncoded: false).dropFirst(sandbox.root.path(percentEncoded: false).count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
