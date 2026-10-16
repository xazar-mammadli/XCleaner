import Foundation
import Testing
@testable import CleanerCore

@Suite("Cleaner")
struct CleanerTests {
    let sandbox: Sandbox
    let home: URL
    let caches: URL
    let trash: FakeTrash
    let log: AuditLog
    let cleaner: Cleaner

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")
        caches = try sandbox.directory("home/Library/Caches")
        trash = FakeTrash(directory: sandbox.url("Trash"))
        log = AuditLog(directory: sandbox.url("Logs"))
        cleaner = Cleaner(safety: SafetyGuard(policy: .forTests(home: home)), trash: trash, auditLog: log)
    }

    private func cacheItem(_ name: String, bytes: Int = 64) throws -> CleanableItem {
        let url = try sandbox.file("home/Library/Caches/\(name)", bytes: bytes)
        return CleanableItem(url: url, category: .userCaches, size: Int64(bytes), safety: .safe, origin: .rule, root: caches)
    }

    @Test func dryRunRemovesNothing() async throws {
        let item = try cacheItem("com.example/cache.db")
        let report = await cleaner.clean([item], method: .dryRun)
        #expect(report.removed.map(\.method) == [.dryRun])
        #expect(report.removedBytes == 64)
        #expect(sandbox.exists(item.url))
        #expect(trash.contents.isEmpty)
    }

    @Test func movesItemsToTheTrash() async throws {
        let item = try cacheItem("com.example/cache.db")
        let report = await cleaner.clean([item], method: .moveToTrash)
        #expect(report.removed.map(\.method) == [.moveToTrash])
        #expect(!sandbox.exists(item.url))
        #expect(trash.contents.count == 1)
    }

    @Test func deletesPermanentlyWhenAsked() async throws {
        let item = try cacheItem("com.example/cache.db")
        let report = await cleaner.clean([item], method: .deletePermanently)
        #expect(report.removed.map(\.method) == [.deletePermanently])
        #expect(!sandbox.exists(item.url))
        #expect(trash.contents.isEmpty)
    }

    @Test func sendsPersonalFilesToTheTrashEvenWhenDeleting() async throws {
        let movie = try sandbox.file("home/Movies/holiday.mov", bytes: 128)
        let item = CleanableItem(url: movie, category: .largeFiles, size: 128, safety: .review, origin: .userSelection, root: home)
        let report = await cleaner.clean([item], method: .deletePermanently)
        #expect(report.removed.map(\.method) == [.moveToTrash])
        #expect(trash.contents.count == 1)
    }

    @Test func removesASymlinkButNeverItsTarget() async throws {
        let target = try sandbox.file("outside/precious.txt")
        let link = try sandbox.symlink("home/Library/Caches/link", to: target)
        let item = CleanableItem(url: link, category: .userCaches, size: 0, safety: .safe, origin: .rule, root: caches)
        let report = await cleaner.clean([item], method: .deletePermanently)
        #expect(report.removed.count == 1)
        #expect(!sandbox.exists(link))
        #expect(sandbox.exists(target))
    }

    @Test func leavesBlockedItemsUntouched() async throws {
        let keychain = try sandbox.file("home/Library/Keychains/login.keychain-db")
        let item = CleanableItem(url: keychain, category: .userCaches, size: 16, safety: .safe, origin: .rule, root: home)
        let report = await cleaner.clean([item], method: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(report.blocked.map(\.reason) == [.protectedLocation(path(home) + "/Library/Keychains")])
        #expect(sandbox.exists(keychain))
    }

    @Test func recordsEveryOutcome() async throws {
        let item = try cacheItem("com.example/cache.db")
        let keychain = try sandbox.file("home/Library/Keychains/login.keychain-db")
        let blocked = CleanableItem(url: keychain, category: .userCaches, size: 16, safety: .safe, origin: .rule, root: caches)
        _ = await cleaner.clean([item, blocked], method: .moveToTrash)

        let entries = await log.entries(on: .now)
        #expect(entries.map(\.action) == [.movedToTrash, .blocked])
        #expect(entries.first?.path == path(item.url))
        #expect(entries.last?.detail?.hasPrefix("protectedLocation:") == true)
    }

    @Test func emptiesTheTrashInsteadOfMovingItThere() async throws {
        let trashFolder = try sandbox.directory("home/.Trash")
        let old = try sandbox.file("home/.Trash/old.txt")
        let item = CleanableItem(url: old, category: .trash, size: 16, safety: .review, origin: .rule, root: trashFolder)
        let report = await cleaner.clean([item], method: .moveToTrash)
        #expect(report.removed.map(\.method) == [.deletePermanently])
        #expect(report.deletedBytes == 16)
        #expect(!sandbox.exists(old))
        #expect(trash.contents.isEmpty)
    }

    @Test func refusesExcludedLocations() async throws {
        let item = try cacheItem("com.example/cache.db")
        let kept = caches.appending(path: "com.example")
        let careful = Cleaner(safety: SafetyGuard(policy: .forTests(home: home, excluding: [kept])), trash: trash, auditLog: log)
        let report = await careful.clean([item], method: .deletePermanently)
        #expect(report.blocked.map(\.reason) == [.excludedByUser(path(kept))])
        #expect(sandbox.exists(item.url))
    }

    @Test func splitsTrashedAndDeletedBytes() async throws {
        let cache = try cacheItem("com.example/cache.db", bytes: 64)
        let trashFolder = try sandbox.directory("home/.Trash")
        let old = try sandbox.file("home/.Trash/old.txt", bytes: 16)
        let trashed = CleanableItem(url: old, category: .trash, size: 16, safety: .review, origin: .rule, root: trashFolder)
        let report = await cleaner.clean([cache, trashed], method: .moveToTrash)
        #expect(report.trashedBytes == 64)
        #expect(report.deletedBytes == 16)
        #expect(report.removedBytes == 80)
    }
}
