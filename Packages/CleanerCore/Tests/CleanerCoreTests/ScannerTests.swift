import Foundation
import Testing
@testable import CleanerCore

@Suite("JunkScanner")
struct JunkScannerTests {
    let sandbox: Sandbox
    let home: URL
    let apps = FakeAppCatalog(
        running: ["com.apple.dt.Xcode": "Xcode", "org.mozilla.firefox": "Firefox"],
        installed: ["com.example.editor": "Example Editor"]
    )

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")
        try sandbox.file("home/Library/Caches/com.example.editor/data.bin", bytes: 20_000)
        try sandbox.file("home/Library/Caches/com.apple.Music/cache.db", bytes: 8_000)
        try sandbox.file("home/Library/Caches/com.apple.bird/state", bytes: 8_000)
        try sandbox.file("home/Library/Caches/Firefox/profile.cache", bytes: 8_000)
        try sandbox.file("home/Library/Caches/.hidden/cache", bytes: 8_000)
        try sandbox.directory("home/Library/Caches/com.example.empty")
        try sandbox.file("home/Library/Logs/DiagnosticReports/App.ips", bytes: 4_000)
        try sandbox.file("home/Library/Logs/XCleaner/cleanup.jsonl", bytes: 4_000)
        try sandbox.file("home/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/out.o", bytes: 30_000)
        try sandbox.file("home/.npm/_cacache/index", bytes: 6_000)
        try sandbox.file("home/.npm/_logs/debug.log", bytes: 6_000)
    }

    private func scan(excluding excluded: [URL] = []) async -> ScanResult {
        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home, excluding: excluded)), apps: apps)
        return await JunkScanner().scan(context)
    }

    @Test func findsCachesLogsAndDeveloperJunk() async {
        let result = await scan()
        #expect(result.names == ["com.example.editor", "com.apple.Music", "Firefox", "DiagnosticReports", "MyApp-abc", "_cacache"])
        #expect(result.issues.isEmpty)
    }

    @Test func namesItemsAfterTheirApps() async {
        let result = await scan()
        #expect(result.item(named: "com.example.editor")?.name == "Example Editor")
        #expect(result.item(named: "_cacache")?.name == "npm")
    }

    @Test func selectsOnlySafeItemsThatAreNotInUse() async {
        let result = await scan()
        #expect(result.item(named: "com.example.editor")?.isSelectedByDefault == true)
        #expect(result.item(named: "com.apple.Music")?.safety == .review)
        #expect(result.item(named: "MyApp-abc")?.note == .appIsRunning("Xcode"))
        #expect(result.item(named: "Firefox")?.note == .appIsRunning("Firefox"))
        #expect(result.items.filter(\.isSelectedByDefault).map(\.url.lastPathComponent).sorted()
            == ["DiagnosticReports", "_cacache", "com.example.editor"])
    }

    @Test func leavesExcludedLocationsOut() async {
        let result = await scan(excluding: [home.appending(path: "Library/Caches/com.example.editor")])
        #expect(!result.names.contains("com.example.editor"))
    }

    @Test func looksIntoGuardedCachesOnlyWithFullDiskAccess() async throws {
        try sandbox.file("home/Library/Caches/com.apple.Safari/cache.db", bytes: 8_000)
        let safety = SafetyGuard(policy: .forTests(home: home))

        let without = await JunkScanner().scan(ScanContext(home: home, safety: safety, apps: apps))
        #expect(!without.names.contains("com.apple.Safari"))
        #expect(without.issues == [.accessDenied(path(sandbox.url("home/Library/Caches/com.apple.Safari")))])

        let with = await JunkScanner().scan(ScanContext(home: home, safety: safety, apps: apps, hasFullDiskAccess: true))
        #expect(with.names.contains("com.apple.Safari"))
        #expect(with.issues.isEmpty)
    }

    @Test func reportsFoldersItCannotRead() async throws {
        let logs = sandbox.url("home/Library/Logs")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path(logs))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(logs)) }
        let result = await scan()
        #expect(result.issues == [.accessDenied(path(logs))])
        #expect(!result.names.contains("DiagnosticReports"))
    }
}

@Suite("TrashScanner")
struct TrashScannerTests {
    @Test func listsTheTrashOnEveryDisk() async throws {
        let sandbox = try Sandbox()
        let home = try sandbox.directory("home")
        try sandbox.file("home/.Trash/old.txt")
        try sandbox.directory("home/.Trash/Old Folder")
        try sandbox.file("home/.Trash/.DS_Store")
        let external = try sandbox.directory("Volumes/USB/.Trashes/501")
        try sandbox.file("Volumes/USB/.Trashes/501/photo.jpg")

        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home)), apps: FakeAppCatalog())
        let result = await TrashScanner(externalTrashes: { [external] }).scan(context)

        #expect(result.names == ["old.txt", "Old Folder", "photo.jpg"])
        #expect(result.items.allSatisfy { $0.category == .trash && !$0.isSelectedByDefault })
    }
}

@Suite("DownloadsScanner")
struct DownloadsScannerTests {
    let sandbox: Sandbox
    let home: URL
    let longAgo = Date.now.addingTimeInterval(-200 * 86_400)
    let lastMonth = Date.now.addingTimeInterval(-40 * 86_400)

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")

        try sandbox.file("home/Downloads/Setup.dmg", bytes: 4_000)
        try sandbox.file("home/Downloads/Report.zip", bytes: 4_000)
        try sandbox.file("home/Downloads/Report/page.txt")
        try sandbox.file("home/Downloads/Fresh.zip", bytes: 4_000)
        try sandbox.markAsScreenshot(try sandbox.file("home/Downloads/shot.png"))
        try sandbox.setCreationDate(sandbox.url("home/Downloads/shot.png"), to: lastMonth)
        try sandbox.markAsScreenshot(try sandbox.file("home/Downloads/new-shot.png"))
        try sandbox.setLastUsed(try sandbox.file("home/Downloads/notes.pdf"), to: longAgo)
        try sandbox.setLastUsed(try sandbox.file("home/Downloads/recent.pdf"), to: .now)
        try sandbox.file("home/Downloads/.hidden")

        try sandbox.file("home/Desktop/Install.pkg", bytes: 4_000)
        try sandbox.markAsScreenshot(try sandbox.file("home/Desktop/desk-shot.png"))
        try sandbox.setCreationDate(sandbox.url("home/Desktop/desk-shot.png"), to: lastMonth)
        try sandbox.setLastUsed(try sandbox.file("home/Desktop/old-desk.pdf"), to: longAgo)
    }

    private func scan() async -> ScanResult {
        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home)), apps: FakeAppCatalog())
        return await DownloadsScanner().scan(context)
    }

    @Test func sortsLeftoversIntoCategories() async {
        let result = await scan()
        let categories = Dictionary(uniqueKeysWithValues: result.items.map { ($0.url.lastPathComponent, $0.category) })
        #expect(categories == [
            "Setup.dmg": .installers, "Report.zip": .archives, "shot.png": .screenshots, "notes.pdf": .oldDownloads,
            "Install.pkg": .installers, "desk-shot.png": .screenshots,
        ])
    }

    @Test func treatsEverythingAsTheUsersOwnFiles() async {
        let result = await scan()
        #expect(result.items.allSatisfy { $0.origin == .userSelection && !$0.isSelectedByDefault })
        #expect(result.item(named: "notes.pdf")?.safety == .caution)
        #expect(result.item(named: "Report.zip")?.note == .alreadyExtracted("Report"))
    }

    @Test func findsTheFolderAnArchiveWasUnpackedInto() {
        let folder = sandbox.url("home/Downloads")
        #expect(DownloadsScanner.unpackedFolder(for: "Report.zip", among: ["Report.zip", "Report"], in: folder) == "Report")
        #expect(DownloadsScanner.unpackedFolder(for: "Fresh.zip", among: ["Fresh.zip"], in: folder) == nil)
        #expect(DownloadsScanner.unpackedFolder(for: "Logs.tar.gz", among: ["Logs.tar.gz", "Logs"], in: folder) == nil)
    }
}

@Suite("LargeFileScanner")
struct LargeFileScannerTests {
    let sandbox: Sandbox
    let home: URL
    let opened = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")
        try sandbox.setLastUsed(try sandbox.file("home/Movies/holiday.mov", bytes: 2_000_000), to: opened)
        try sandbox.file("home/Downloads/backup.zip", bytes: 1_500_000)
        try sandbox.file("home/Documents/notes.txt", bytes: 1_000)
        try sandbox.file("home/Library/huge.bin", bytes: 3_000_000)
        try sandbox.file("home/.hidden/huge.bin", bytes: 3_000_000)
        try sandbox.file("home/Pictures/Photos Library.photoslibrary/database", bytes: 3_000_000)
        try sandbox.file("home/Movies/.secret.mov", bytes: 2_000_000)
    }

    private func scan(excluding excluded: [URL] = [], progress: (@Sendable (Int) -> Void)? = nil) async -> ScanResult {
        let context = ScanContext(home: home, safety: SafetyGuard(policy: .forTests(home: home, excluding: excluded)), apps: FakeAppCatalog())
        return await LargeFileScanner(minimumSize: 1_000_000).scan(context, progress: progress)
    }

    @Test func findsBigFilesBiggestFirst() async {
        let result = await scan()
        #expect(result.items.map(\.url.lastPathComponent) == ["holiday.mov", "backup.zip"])
        #expect(result.items.map(\.kind) == [.video, .archive])
        #expect(result.item(named: "holiday.mov")?.date == opened)
        #expect(result.items.allSatisfy { $0.origin == .userSelection && $0.category == .largeFiles })
    }

    @Test func leavesExcludedFoldersOut() async {
        let result = await scan(excluding: [home.appending(path: "Movies")])
        #expect(result.names == ["backup.zip"])
    }

    @Test func reportsProgress() async {
        let counter = Counter()
        _ = await scan(progress: { counter.set($0) })
        #expect(counter.value == 4)
    }
}
