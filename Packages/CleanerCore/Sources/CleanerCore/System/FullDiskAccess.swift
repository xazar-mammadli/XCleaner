import Foundation

public enum FullDiskAccessStatus: Sendable, Equatable {
    case granted
    case denied
    case unknown
}

/// Tells whether macOS gave XCleaner Full Disk Access. There is no API for this, so it tries to open files
/// that only apps with Full Disk Access can read. Opening them never shows a permission prompt.
public struct FullDiskAccessChecker: Sendable {
    public let probePaths: [String]

    public init(probePaths: [String]) {
        self.probePaths = probePaths
    }

    public static func standard(home: URL) -> FullDiskAccessChecker {
        FullDiskAccessChecker(probePaths: [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path(percentEncoded: false),
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ])
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public func check() -> FullDiskAccessStatus {
        var refused = false
        for path in probePaths {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            if errno == EPERM || errno == EACCES { refused = true }
        }
        return refused ? .denied : .unknown
    }
}
