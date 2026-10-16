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

/// What a found item is, which decides how it is grouped and explained.
public enum CleanupCategory: String, Sendable, Codable, CaseIterable {
    case userCaches, logs, developerJunk, trash, installers, archives, screenshots, oldDownloads, largeFiles
    /// Caches and logs in the system folders, which only an administrator may remove.
    case systemCaches, systemLogs
    /// Copies of attachments the user opened in Mail.
    case mailAttachments
    /// A browser's cache, history or cookies.
    case browserData
    /// An app bundle itself.
    case application
    /// Files an app keeps in the home Library: preferences, support files, caches, containers…
    case appData
}

/// Where in `~/Library` an app keeps a piece of its data.
public enum LibraryLocation: String, Sendable, Codable, CaseIterable {
    case applicationSupport, caches, preferences, containers, groupContainers, applicationScripts
    case savedState, logs, webKit, httpStorages, cookies, launchAgents

    /// The folder, relative to `~/Library`.
    public var folder: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .applicationScripts: "Application Scripts"
        case .savedState: "Saved Application State"
        case .logs: "Logs"
        case .webKit: "WebKit"
        case .httpStorages: "HTTPStorages"
        case .cookies: "Cookies"
        case .launchAgents: "LaunchAgents"
        }
    }

    /// Other apps' containers are guarded by a macOS permission prompt; they are only looked at with Full Disk Access.
    public var needsFullDiskAccess: Bool {
        self == .containers || self == .groupContainers || self == .applicationScripts
    }
}

/// The broad kind of a user file, used to filter large files.
public enum FileKind: String, Sendable, Codable, CaseIterable {
    case video, audio, image, archive, diskImage, document, other
}

/// Something the user should know about an item before removing it.
public enum ItemNote: Sendable, Hashable {
    /// The app that owns the item is running, and removing its files now could disturb it.
    case appIsRunning(String)
    /// An archive whose contents already sit unpacked in the named folder next to it.
    case alreadyExtracted(String)
    /// Another app from the same developer is still installed and may share this data.
    case sameDeveloperInstalled(String)
}

/// Something a scan found that the user may choose to remove.
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let category: CleanupCategory
    /// Space it takes on disk, in bytes, as measured by the scan.
    public let size: Int64
    public let safety: SafetyLevel
    public let origin: ItemOrigin
    /// The folder the scan looked in. The item must still be strictly inside it when it is removed.
    public let root: URL
    /// When the item was last opened, or else when it last changed, if known.
    public let date: Date?
    public let kind: FileKind?
    public let note: ItemNote?
    /// For app data: which Library folder it sits in.
    public let location: LibraryLocation?

    public init(
        url: URL,
        name: String? = nil,
        category: CleanupCategory,
        size: Int64,
        safety: SafetyLevel,
        origin: ItemOrigin,
        root: URL,
        date: Date? = nil,
        kind: FileKind? = nil,
        note: ItemNote? = nil,
        location: LibraryLocation? = nil
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.category = category
        self.size = size
        self.safety = safety
        self.origin = origin
        self.root = root
        self.date = date
        self.kind = kind
        self.note = note
        self.location = location
    }

    /// Only items that are safe to remove and not in use start out selected.
    public var isSelectedByDefault: Bool {
        // Removing those asks for a password, so the user opts in.
        guard safety == .safe, !needsAdministrator else { return false }
        if case .appIsRunning = note { return false }
        return true
    }
}
