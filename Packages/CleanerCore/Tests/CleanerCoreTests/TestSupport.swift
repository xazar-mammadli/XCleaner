import Foundation
import Testing
@testable import CleanerCore

/// A private folder tree for one test, deleted when the test ends. Tests never touch real user files.
final class Sandbox: Sendable {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "CleanerCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The canonical form (/private/var/…), which is what SafetyGuard reports back.
        let canonical = try #require(PathUtilities.realPath(base.path(percentEncoded: false)))
        root = URL(filePath: canonical, directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func symlink(_ relative: String, to destination: URL) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// Whether anything is at `url`, without following a symlink there.
    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }
}

/// Stands in for the Finder Trash so tests never put anything in the real one.
struct FakeTrash: TrashHandling {
    let directory: URL

    func moveToTrash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    var contents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }
}

extension SafetyPolicy {
    /// The standard policy for a home folder inside a test sandbox. The sandbox lives in the temporary
    /// folder (/private/var/folders), which the real policy protects, so only that one entry is lifted.
    static func forTests(home: URL) -> SafetyPolicy {
        var policy = SafetyPolicy.standard(home: home)
        policy.neverDeleteTrees.removeAll { $0 == "/private/var/folders" }
        return policy
    }
}

func path(_ url: URL) -> String {
    url.path(percentEncoded: false)
}
