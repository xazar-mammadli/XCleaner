import Foundation
import Testing
@testable import CleanerCore

@Suite("DirectorySizer")
struct DirectorySizerTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func addsUpTheFilesInAFolder() throws {
        let folder = try sandbox.directory("folder")
        for index in 0..<3 {
            try sandbox.file("folder/file\(index)", bytes: 10_000)
        }
        let result = DirectorySizer.allocatedSize(of: folder)
        #expect(result.fileCount == 3)
        #expect(result.bytes >= 30_000)
        #expect(result.unreadableCount == 0)
    }

    @Test func countsHardLinksOnce() throws {
        let folder = try sandbox.directory("folder")
        let original = try sandbox.file("folder/original", bytes: 100_000)
        let before = DirectorySizer.allocatedSize(of: folder).bytes
        try FileManager.default.linkItem(at: original, to: sandbox.url("folder/link"))
        #expect(DirectorySizer.allocatedSize(of: folder).bytes == before)
    }

    @Test func doesNotFollowSymlinks() throws {
        let big = try sandbox.file("elsewhere/big", bytes: 1_000_000)
        let folder = try sandbox.directory("folder")
        try sandbox.symlink("folder/link", to: big)
        #expect(DirectorySizer.allocatedSize(of: folder).bytes < 100_000)
    }

    @Test func reportsAMissingPath() {
        let result = DirectorySizer.allocatedSize(of: sandbox.url("missing"))
        #expect(result.bytes == 0)
        #expect(result.unreadableCount == 1)
    }
}

@Suite("FullDiskAccessChecker")
struct FullDiskAccessCheckerTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    @Test func grantedWhenAProtectedFileOpens() throws {
        let probe = try sandbox.file("TCC.db")
        #expect(FullDiskAccessChecker(probePaths: [path(probe)]).check() == .granted)
    }

    @Test func deniedWhenProtectedFilesRefuseToOpen() throws {
        let probe = try sandbox.file("TCC.db")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path(probe))
        #expect(FullDiskAccessChecker(probePaths: [path(probe)]).check() == .denied)
    }

    @Test func unknownWhenNothingCanBeProbed() {
        #expect(FullDiskAccessChecker(probePaths: [path(sandbox.url("missing"))]).check() == .unknown)
    }
}

@Suite("AuditLog")
struct AuditLogTests {
    @Test func listsEveryEntryNewestFirst() async throws {
        let sandbox = try Sandbox()
        let log = AuditLog(directory: sandbox.url("Logs"))
        await log.record(.init(date: .now.addingTimeInterval(-86_400), action: .deleted, path: "/a", bytes: 1))
        await log.record(.init(action: .movedToTrash, path: "/b", bytes: 2))
        await log.record(.init(action: .dryRun, path: "/c", bytes: 3))
        #expect(await log.allEntries().map(\.path) == ["/c", "/b", "/a"])
    }

    @Test func clearingRemovesOnlyItsOwnFiles() async throws {
        let sandbox = try Sandbox()
        let log = AuditLog(directory: sandbox.url("Logs"))
        await log.record(.init(date: .now.addingTimeInterval(-86_400), action: .deleted, path: "/a", bytes: 1))
        await log.record(.init(action: .movedToTrash, path: "/b", bytes: 2))
        let other = try sandbox.file("Logs/notes.txt")
        try await log.clear()
        #expect(await log.allEntries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}

@Suite("VolumeUsage")
struct VolumeUsageTests {
    @Test func splitsTheDiskIntoUsedAndAvailable() throws {
        let sandbox = try Sandbox()
        let usage = try VolumeUsage.current(for: sandbox.root)
        #expect(usage.totalBytes > 0)
        #expect(usage.usedBytes + usage.availableBytes == usage.totalBytes)
    }
}
