import Foundation

/// How sure we are that removing an item is harmless.
public enum SafetyLevel: String, Sendable, Codable, CaseIterable {
    /// Recreated automatically when needed, like caches and logs. Selected by default.
    case safe
    /// Probably unneeded, but worth a look first, like old installers.
    case review
    /// Might still matter to the user. Never selected by default.
    case caution
}

/// How an item got onto the removal list. It decides which safety rules apply.
public enum ItemOrigin: String, Sendable, Codable {
    /// Found by a cleanup rule (caches, logs…). Rules may never reach into personal folders.
    case rule
    /// Picked by the user (large files, duplicates…). Allowed in personal folders, but only ever moved to the Trash.
    case userSelection
}

public enum DeletionMethod: String, Sendable, Codable, CaseIterable {
    case moveToTrash
    case deletePermanently
    /// Runs every check and reports what would happen, but removes nothing.
    case dryRun
}

/// Something a scan found that the user may choose to remove.
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    /// Space it takes on disk, in bytes, as measured by the scan.
    public let size: Int64
    public let safety: SafetyLevel
    public let origin: ItemOrigin
    /// The folder the scan looked in. The item must still be strictly inside it when it is removed.
    public let root: URL

    public init(url: URL, size: Int64, safety: SafetyLevel, origin: ItemOrigin, root: URL) {
        self.url = url
        self.size = size
        self.safety = safety
        self.origin = origin
        self.root = root
    }
}
