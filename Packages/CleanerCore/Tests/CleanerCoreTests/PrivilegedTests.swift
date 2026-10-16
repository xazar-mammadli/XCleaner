import Foundation
import Testing
@testable import CleanerCore

@Suite("Privileged")
struct PrivilegedTests {
    @Test func requestsSurviveTheTripThroughJSON() throws {
        let owner = TrashOwner(uid: 501, gid: 20, home: "/Users/someone")
        let requests: [PrivilegedRequest] = [
            .remove(paths: ["/Library/Caches/com.example.app", "/private/var/log/wifi.log.0.bz2"], method: .moveToTrash, owner: owner),
            .setDaemon(label: "com.example.daemon", enabled: false, plist: "/Library/LaunchDaemons/com.example.daemon.plist"),
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(PrivilegedRequest.self, from: data) == request)
        }
    }

    @Test func onlyRemovesInsideTheAllowedFolders() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.directory("System/Caches").path(percentEncoded: false)
        try sandbox.file("System/Caches/com.example.app/cache.db")
        try sandbox.file("System/Other/keep.txt")
        try sandbox.symlink("System/Caches/sneaky", to: sandbox.url("System/Other"))

        #expect(PrivilegedRunner.allowedRoot(for: root + "/com.example.app", among: [root]) == root)
        #expect(PrivilegedRunner.allowedRoot(for: root, among: [root]) == nil)
        #expect(PrivilegedRunner.allowedRoot(for: sandbox.url("System/Other/keep.txt").path(percentEncoded: false), among: [root]) == nil)
        #expect(PrivilegedRunner.allowedRoot(for: "relative/path", among: [root]) == nil)
        // A link is judged as the link itself, so it stays inside; following it would leave the folder.
        #expect(PrivilegedRunner.allowedRoot(for: root + "/sneaky", among: [root]) == root)
    }

    @Test func movesItemsToTheOwnersTrash() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.directory("System/Caches").path(percentEncoded: false)
        try sandbox.file("System/Caches/com.example.app/cache.db", bytes: 4_096)
        try sandbox.file("System/Other/keep.txt")
        let home = try sandbox.directory("Home")
        try sandbox.directory("Home/.Trash")
        let owner = TrashOwner(uid: getuid(), gid: getgid(), home: home.path(percentEncoded: false))

        let outside = sandbox.url("System/Other/keep.txt").path(percentEncoded: false)
        let response = await PrivilegedRunner.remove(
            [root + "/com.example.app", outside], method: .moveToTrash, owner: owner, roots: [root], policy: .forTests(home: home)
        )
        #expect(response.succeeded)
        #expect(response.outcomes.first { $0.path == outside }?.result == .blocked)
        let removed = try #require(response.outcomes.first { $0.result == .removed })
        #expect(removed.method == .moveToTrash)
        #expect(removed.bytes > 0)
        #expect(sandbox.exists(sandbox.url("Home/.Trash/com.example.app/cache.db")))
        #expect(!sandbox.exists(sandbox.url("System/Caches/com.example.app")))
        #expect(sandbox.exists(sandbox.url("System/Other/keep.txt")))
    }

    @Test func refusesATrashThatIsNotTheOwners() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.directory("System/Caches").path(percentEncoded: false)
        try sandbox.file("System/Caches/item")
        let home = try sandbox.directory("Home")
        // No .Trash folder in this home.
        let owner = TrashOwner(uid: getuid(), gid: getgid(), home: home.path(percentEncoded: false))
        let response = await PrivilegedRunner.remove(
            [root + "/item"], method: .moveToTrash, owner: owner, roots: [root], policy: .forTests(home: home)
        )
        #expect(!response.succeeded)
        #expect(sandbox.exists(sandbox.url("System/Caches/item")))
    }

    @Test func refusesDaemonsOutsideTheirFolder() {
        #expect(!PrivilegedRunner.setDaemon(label: "com.example; rm -rf /", enabled: false, plist: "/Library/LaunchDaemons/x.plist").succeeded)
        #expect(!PrivilegedRunner.setDaemon(label: "com.example.ok", enabled: false, plist: "/etc/hosts").succeeded)
    }

    @Test func blockReasonsReadBackFromTheirCode() {
        let reasons: [BlockReason] = [
            .notAFileURL, .doesNotExist, .unresolvablePath, .protectedLocation("/System"), .protectedContainer("/Library/Caches"),
            .personalData("/Users/a/Documents"), .insideSealedPackage("/Applications/A.app"), .excludedByUser("/x:y"), .volumeRoot,
            .outsideAllowedRoot,
        ]
        for reason in reasons {
            #expect(BlockReason(code: reason.code) == reason)
        }
    }

    @Test func systemItemsWaitForTheUserToPickThem() {
        let system = CleanableItem(
            url: URL(filePath: "/Library/Caches/com.example.app"), category: .systemCaches, size: 10, safety: .safe,
            origin: .rule, root: URL(filePath: "/Library/Caches")
        )
        let user = CleanableItem(
            url: URL(filePath: "/Users/someone/Library/Caches/x"), category: .userCaches, size: 10, safety: .safe,
            origin: .rule, root: URL(filePath: "/Users/someone/Library/Caches")
        )
        #expect(system.needsAdministrator)
        #expect(!system.isSelectedByDefault)
        #expect(!user.needsAdministrator)
        #expect(user.isSelectedByDefault)
    }

    @Test func systemRulesOfferOnlyWhatTheyShould() {
        let caches = CleanupRule.system[0]
        #expect(caches.offers("com.microsoft.autoupdate.fba"))
        #expect(!caches.offers("com.apple.iconservices.store"))
        #expect(!caches.offers("ColorSync"))
        let archives = CleanupRule.system[2]
        #expect(archives.offers("system.log.0.gz"))
        #expect(archives.offers("wifi.log.3.bz2"))
        #expect(archives.offers("keybagd.log.0"))
        #expect(!archives.offers("install.log"))
        #expect(!archives.offers("system.log"))
        #expect(caches.location(in: URL(filePath: "/Users/someone")).path(percentEncoded: false).hasPrefix("/Library/Caches"))
    }
}
