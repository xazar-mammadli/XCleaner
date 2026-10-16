import Foundation
import Testing
@testable import CleanerCore

extension Sandbox {
    /// A minimal app bundle: just enough Info.plist for the inventory to read.
    @discardableResult
    func app(_ relative: String, id: String, version: String = "1.0", bytes: Int = 2_000) throws -> URL {
        let url = try directory(relative)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try directory("\(relative)/Contents")
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        try file("\(relative)/Contents/MacOS/binary", bytes: bytes)
        return url
    }
}

@Suite("AppInventory")
struct AppInventoryTests {
    @Test func listsAppsIncludingOnesInSubfolders() throws {
        let sandbox = try Sandbox()
        try sandbox.app("Applications/Editor.app", id: "com.example.editor", version: "2.1")
        try sandbox.app("Applications/Suite/Viewer.app", id: "com.example.viewer")
        try sandbox.app("Applications/Deep/Deeper/Hidden.app", id: "com.example.hidden")
        try sandbox.app("Applications/XCleaner.app", id: "com.xazar.xcleaner")
        try sandbox.directory("Applications/Broken.app")

        let apps = AppInventory(folders: [sandbox.url("Applications")]).apps(excluding: ["com.xazar.xcleaner"])
        #expect(apps.map(\.name) == ["Editor", "Viewer"])
        #expect(apps.first?.version == "2.1")
        #expect(apps.first?.bundleIdentifier == "com.example.editor")
    }

    @Test func offersTheBundleOnlyForTheTrash() throws {
        let sandbox = try Sandbox()
        let url = try sandbox.app("Applications/Editor.app", id: "com.example.editor")
        let app = try #require(AppInventory.read(url))
        let item = app.asItem(size: 42)
        #expect(item.origin == .userSelection)
        #expect(item.category == .application)
        #expect(PathUtilities.realPath(path(item.root)) == PathUtilities.realPath(path(sandbox.url("Applications"))))
    }
}

@Suite("LeftoverFinder")
struct LeftoverFinderTests {
    let sandbox: Sandbox
    let home: URL

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")
        let library = "home/Library"
        try sandbox.file("\(library)/Preferences/com.example.editor.plist")
        try sandbox.file("\(library)/Preferences/ByHost/com.example.editor.ABC123.plist")
        try sandbox.file("\(library)/Application Support/com.example.editor/state.db", bytes: 4_000)
        try sandbox.file("\(library)/Application Support/Example Editor/settings.json")
        try sandbox.file("\(library)/Caches/com.example.editor.ShipIt/update.zip", bytes: 4_000)
        try sandbox.file("\(library)/Caches/com.example.editorial/other.db")
        try sandbox.file("\(library)/Saved Application State/com.example.editor.savedState/window.data")
        try sandbox.file("\(library)/HTTPStorages/com.example.editor.binarycookies")
        try sandbox.file("\(library)/Containers/com.example.editor/Data/file")
        try sandbox.file("\(library)/Group Containers/group.com.example.shared/data")
        try sandbox.file("\(library)/Group Containers/group.com.other.app/data")
        try sandbox.file("\(library)/LaunchAgents/com.example.editor.updater.plist")
    }

    private func find(fullDiskAccess: Bool) -> ScanResult {
        let context = ScanContext(
            home: home, safety: SafetyGuard(policy: .forTests(home: home)), apps: FakeAppCatalog(), hasFullDiskAccess: fullDiskAccess
        )
        return LeftoverFinder().leftovers(
            bundleIdentifier: "com.example.editor", name: "Example Editor", appGroups: ["group.com.example.shared"], context: context
        )
    }

    @Test func findsFilesNamedAfterTheApp() {
        let result = find(fullDiskAccess: true)
        #expect(result.names == [
            "com.example.editor.plist", "com.example.editor.ABC123.plist", "com.example.editor", "Example Editor",
            "com.example.editor.ShipIt", "com.example.editor.savedState", "com.example.editor.binarycookies",
            "group.com.example.shared", "com.example.editor.updater.plist",
        ])
        #expect(!result.names.contains("com.example.editorial"))
        #expect(!result.names.contains("group.com.other.app"))
    }

    @Test func selectsOnlyCertainMatches() {
        let result = find(fullDiskAccess: true)
        let selected = Set(result.items.filter(\.isSelectedByDefault).map(\.url.lastPathComponent))
        #expect(!selected.contains("Example Editor"))
        #expect(!selected.contains("group.com.example.shared"))
        #expect(!selected.contains("com.example.editor.updater.plist"))
        #expect(selected.contains("com.example.editor.plist"))
        #expect(result.item(named: "com.example.editor.plist")?.location == .preferences)
    }

    @Test func leavesContainersAloneWithoutFullDiskAccess() {
        let result = find(fullDiskAccess: false)
        #expect(!result.names.contains("group.com.example.shared"))
        let containerItems = result.items.filter { $0.location == .containers }
        #expect(containerItems.isEmpty)
        #expect(result.issues.contains(.accessDenied(path(sandbox.url("home/Library/Containers")))))
    }
}

@Suite("OrphanFinder")
struct OrphanFinderTests {
    @Test func findsDataOfAppsThatAreGone() async throws {
        let sandbox = try Sandbox()
        let home = try sandbox.directory("home")
        try sandbox.file("home/Library/Application Support/com.gone.app/data.db", bytes: 6_000)
        try sandbox.file("home/Library/Preferences/com.gone.app.plist")
        try sandbox.file("home/Library/Caches/com.gone.app/cache")
        try sandbox.file("home/Library/Caches/com.example.editor/cache")
        try sandbox.file("home/Library/Caches/com.example.editor.helper/cache")
        try sandbox.file("home/Library/Caches/com.apple.Music/cache")
        try sandbox.file("home/Library/Preferences/systemgroup.com.apple.icloud.settings.plist")
        try sandbox.file("home/Library/Preferences/org.cups.PrintingPrefs.plist")
        try sandbox.file("home/Library/Caches/Google/cache")
        try sandbox.file("home/Library/Containers/com.gone.sandboxed/Data/file")

        let apps = FakeAppCatalog(installed: ["com.example.editor": "Editor"])
        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home)), apps: apps)
        let (groups, issues) = await OrphanFinder().scan(context)

        #expect(groups.map(\.bundleIdentifier) == ["com.gone.app"])
        #expect(groups.first?.displayName == "app")
        #expect(groups.first?.items.count == 3)
        #expect(Set(groups.first?.items.compactMap(\.location) ?? []) == [.applicationSupport, .preferences, .caches])
        #expect(groups.first?.items.allSatisfy { !$0.isSelectedByDefault } == true)
        #expect(issues.contains(.accessDenied(path(sandbox.url("home/Library/Containers")))))
    }

    @Test func takesCareWithDevelopersThatStillHaveApps() async throws {
        let sandbox = try Sandbox()
        let home = try sandbox.directory("home")
        try sandbox.file("home/Library/Preferences/com.vendor.shared.plist")
        try sandbox.file("home/Library/Preferences/com.solo.gone.plist")
        try sandbox.file("home/Library/Caches/org.tool.cache/data")
        let suite = InstalledApp(url: URL(filePath: "/Applications/Suite.app"), bundleIdentifier: "com.vendor.suite", name: "Suite", version: nil)

        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home)), apps: FakeAppCatalog())
        let (groups, _) = await OrphanFinder().scan(context, installedApps: [suite])

        #expect(Set(groups.map(\.bundleIdentifier)) == ["com.vendor.shared", "com.solo.gone"])
        let shared = try #require(groups.first { $0.bundleIdentifier == "com.vendor.shared" })
        #expect(shared.items.allSatisfy { $0.safety == .caution && $0.note == .sameDeveloperInstalled("Suite") })
        #expect(groups.first { $0.bundleIdentifier == "com.solo.gone" }?.items.first?.note == nil)
    }

    @Test func findsTheDeveloperOfAnIdentifier() {
        #expect(OrphanFinder.developer(of: "com.Example.app") == "com.example")
        #expect(OrphanFinder.developer(of: "group.com.example.app") == "com.example")
        #expect(OrphanFinder.developer(of: "8DKG4XB37M.group.com.example.app") == "com.example")
        #expect(OrphanFinder.developer(of: "systemgroup.com.apple.icloud.settings") == "com.apple")
    }

    @Test func recognisesBundleIdentifiers() {
        #expect(OrphanFinder.looksLikeBundleIdentifier("com.example.app"))
        #expect(OrphanFinder.looksLikeBundleIdentifier("org.mozilla.firefox-esr"))
        #expect(!OrphanFinder.looksLikeBundleIdentifier("Google"))
        #expect(!OrphanFinder.looksLikeBundleIdentifier("com.example"))
        #expect(!OrphanFinder.looksLikeBundleIdentifier("com..example"))
        #expect(!OrphanFinder.looksLikeBundleIdentifier("My Folder.v2.backup"))
    }
}

@Suite("DiskMap")
struct DiskMapTests {
    @Test func measuresATreeAndFoldsSmallEntries() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.directory("root")
        try sandbox.file("root/Movies/big.mov", bytes: 3_000_000)
        try sandbox.file("root/Movies/small.txt", bytes: 1_000)
        try sandbox.file("root/Documents/report.pdf", bytes: 1_500_000)
        try sandbox.file("root/tiny/note.txt", bytes: 500)
        try sandbox.file("root/Editor.app/Contents/MacOS/binary", bytes: 2_000_000)

        let tree = try #require(await DiskMapScanner(minimumNodeSize: 1_000_000).scan(root))
        #expect(tree.children.map(\.name) == ["Movies", "Editor.app", "Documents"])
        let movies = try #require(tree.children.first)
        #expect(movies.children.map(\.name) == ["big.mov"])
        #expect(movies.otherBytes > 0)
        #expect(tree.children.first(where: { $0.name == "Editor.app" })?.children.isEmpty == true)
        #expect(tree.size == tree.children.reduce(0) { $0 + $1.size } + tree.otherBytes)
    }

    @Test func removesANodeAndShrinksItsParents() {
        let file = DiskNode(url: URL(filePath: "/r/a/f"), name: "f", size: 30, isDirectory: false)
        let other = DiskNode(url: URL(filePath: "/r/a/g"), name: "g", size: 20, isDirectory: false)
        let folder = DiskNode(url: URL(filePath: "/r/a"), name: "a", size: 60, isDirectory: true, children: [file, other], otherBytes: 10)
        let root = DiskNode(url: URL(filePath: "/r"), name: "r", size: 100, isDirectory: true, children: [folder], otherBytes: 40)

        let updated = root.removing(URL(filePath: "/r/a/f"))
        #expect(updated.size == 70)
        #expect(updated.children.first?.size == 30)
        #expect(updated.children.first?.children.map(\.name) == ["g"])
        #expect(updated.node(at: URL(filePath: "/r/a/g"))?.size == 20)
    }

    @Test func treemapFillsTheAreaWithoutOverlaps() {
        let values: [Double] = [60, 25, 10, 4, 1, 0]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frames = Treemap.layout(values, in: bounds)

        #expect(frames[5] == .zero)
        let areas = frames.map { Double($0.width * $0.height) }
        let total = areas.reduce(0, +)
        #expect(abs(total - 120_000) < 1)
        for (index, value) in values.enumerated() where value > 0 {
            #expect(abs(areas[index] / total - value / 100) < 0.001)
            #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frames[index]))
        }
        for first in frames.indices {
            for second in frames.indices where second > first {
                let overlap = frames[first].intersection(frames[second])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.5)
            }
        }
    }
}
