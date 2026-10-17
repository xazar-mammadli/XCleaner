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
    func file(_ relative: String, contents: Data) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
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
    static func forTests(home: URL, excluding excluded: [URL] = []) -> SafetyPolicy {
        var policy = SafetyPolicy.standard(home: home, excluding: excluded)
        policy.neverDeleteTrees.removeAll { $0 == "/private/var/folders" }
        return policy
    }
}

/// A fixed set of installed and running apps.
struct FakeAppCatalog: AppCatalog {
    var running: [String: String] = [:]
    var installed: [String: String] = [:]

    func runningApplications() -> [String: String] { running }
    func applicationName(forBundleIdentifier bundleIdentifier: String) -> String? { installed[bundleIdentifier] }
}

extension Sandbox {
    /// Sets the "Date Last Opened" Finder shows.
    func setLastUsed(_ url: URL, to date: Date) throws {
        var timespec = (Int64(date.timeIntervalSince1970).littleEndian, Int64(0).littleEndian)
        try setExtendedAttribute("com.apple.lastuseddate#PS", on: url, to: withUnsafeBytes(of: &timespec) { Data($0) })
    }

    /// Marks a file the way macOS marks the screenshots it saves.
    func markAsScreenshot(_ url: URL) throws {
        let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        try setExtendedAttribute("com.apple.metadata:kMDItemIsScreenCapture", on: url, to: flag)
    }

    func setCreationDate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path(url))
    }

    private func setExtendedAttribute(_ name: String, on url: URL, to value: Data) throws {
        let status = value.withUnsafeBytes { setxattr(path(url), name, $0.baseAddress, value.count, 0, 0) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Collects values reported from any thread, such as progress updates.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

/// Counts from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    var value: Int { lock.withLock { current } }

    func set(_ newValue: Int) {
        lock.withLock { current = newValue }
    }
}

extension ScanResult {
    var names: Set<String> { Set(items.map(\.url.lastPathComponent)) }

    func item(named name: String) -> CleanableItem? {
        items.first { $0.url.lastPathComponent == name }
    }
}

func path(_ url: URL) -> String {
    url.path(percentEncoded: false)
}

/// Bytes that look random and differ everywhere for different seeds, so files made from them only match on purpose.
func noise(_ seed: UInt64, count: Int) -> Data {
    var state = (seed &+ 1) &* 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state)
    }
    return Data(bytes)
}
