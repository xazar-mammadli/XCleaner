import Foundation

/// Answers questions about installed and running apps. The app implements it with NSWorkspace; tests use a stand-in.
public protocol AppCatalog: Sendable {
    /// Bundle identifier → display name, for every app running right now.
    func runningApplications() -> [String: String]
    func applicationName(forBundleIdentifier bundleIdentifier: String) -> String?
}

/// What a scan needs to know about the Mac it runs on.
public struct ScanContext: Sendable {
    public let home: URL
    public let safety: SafetyGuard
    public let apps: any AppCatalog
    /// Without Full Disk Access, touching some folders makes macOS stop the scan and ask the user, so those are left out.
    public let hasFullDiskAccess: Bool
    public let now: Date

    public init(home: URL, safety: SafetyGuard, apps: any AppCatalog, hasFullDiskAccess: Bool = false, now: Date = .now) {
        self.home = home
        self.safety = safety
        self.apps = apps
        self.hasFullDiskAccess = hasFullDiskAccess
        self.now = now
    }
}

public enum ScanIssue: Sendable, Hashable {
    /// macOS refused to show a folder's contents, usually because Full Disk Access is off.
    case accessDenied(String)
}

public struct ScanResult: Sendable {
    public var items: [CleanableItem] = []
    public var issues: Set<ScanIssue> = []

    public init(items: [CleanableItem] = [], issues: Set<ScanIssue> = []) {
        self.items = items
        self.issues = issues
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum DirectoryListing {
    enum Outcome {
        case names([String])
        case missing
        case denied
    }

    static func children(of folder: URL) -> Outcome {
        do {
            return .names(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .denied
        } catch {
            return .missing
        }
    }
}
