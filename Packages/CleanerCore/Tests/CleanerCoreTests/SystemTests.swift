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

@Suite("VolumeUsage")
struct VolumeUsageTests {
    @Test func splitsTheDiskIntoUsedAndAvailable() throws {
        let sandbox = try Sandbox()
        let usage = try VolumeUsage.current(for: sandbox.root)
        #expect(usage.totalBytes > 0)
        #expect(usage.usedBytes + usage.availableBytes == usage.totalBytes)
    }
}
