import Foundation

/// A file or folder Finder doesn't show: its name starts with a dot, or it carries Finder's hidden flag.
public struct HiddenItem: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        /// Keys, tokens and passwords of command-line tools. Never offered for removal.
        case credentials
        /// Kept by macOS itself, such as `~/Library`. Never offered for removal.
        case system
        case other
    }

    public var id: URL { url }
    public let url: URL
    public let isFolder: Bool
    /// Space it takes on disk; nil when it wasn't measured.
    public let size: Int64?
    /// Hidden by Finder's hidden flag, which can be lifted. A name starting with a dot hides an item regardless.
    public let isHiddenByFlag: Bool
    public let role: Role
    public let modified: Date?
    /// The folder that was looked in.
    public let root: URL

    public var name: String { url.lastPathComponent }
    public var hasDotName: Bool { name.hasPrefix(".") }

    /// The same item after its hidden flag changed.
    public func withHiddenFlag(_ isHiddenByFlag: Bool) -> HiddenItem {
        HiddenItem(url: url, isFolder: isFolder, size: size, isHiddenByFlag: isHiddenByFlag, role: role, modified: modified, root: root)
    }
    public var canRemove: Bool { role == .other }

    /// The item as one to remove. The user picked it, so it only ever goes to the Trash.
    public var cleanableItem: CleanableItem {
        CleanableItem(
            url: url, category: .hiddenItems, size: size ?? DirectorySizer.allocatedSize(of: url).bytes, safety: .caution,
            origin: .userSelection, root: root, date: modified
        )
    }
}

/// Finds hidden files and folders: those right inside a folder, measured, or anywhere below it by name.
public struct HiddenFileScanner: Sendable {
    public let folder: URL
    public let home: URL
    public let safety: SafetyGuard

    /// Names that are noise rather than anything to look at.
    static let ignored: Set<String> = [".DS_Store", ".localized"]
    /// Hidden items macOS keeps: in the home folder and at the top of a disk.
    static let system: Set<String> = [
        ".Trash", ".CFUserTextEncoding", ".Trashes", ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100",
        ".TemporaryItems", ".VolumeIcon.icns", ".file", ".vol", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
    ]
    /// Folders a search never walks into: packages such as apps, and folders holding many thousands of files of little
    /// interest.
    static let searchSkips: Set<String> = [".git", "node_modules", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"]

    public init(folder: URL, home: URL, safety: SafetyGuard) {
        self.folder = folder
        self.home = home
        self.safety = safety
    }

    /// The hidden items right inside the folder, biggest first. `~/Library` is listed but never measured: measuring it
    /// would walk into folders macOS guards with permission prompts. Neither are system folders.
    public func topLevel() -> [HiddenItem] {
        guard let root = PathUtilities.realPath(folder.path(percentEncoded: false)),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return [] }
        let homePath = PathUtilities.realPath(home.path(percentEncoded: false)) ?? home.path(percentEncoded: false)
        var items: [HiddenItem] = []
        for name in names where !Self.ignored.contains(name) {
            if Task.isCancelled { return [] }
            let path = root == "/" ? "/" + name : root + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isFlagged = info.st_flags & UInt32(UF_HIDDEN) != 0
            guard name.hasPrefix(".") || isFlagged else { continue }
            // The Trash has a tool of its own.
            guard !(root == homePath && name == ".Trash") else { continue }
            let url = URL(filePath: path)
            let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
            let role = role(of: url, name: name, in: root, home: homePath)
            let measurable = role != .system && !(root == homePath && name == "Library") && safety.acceptsItems(in: url)
            let size: Int64? = !isFolder ? Int64(info.st_blocks) * 512 : measurable ? DirectorySizer.allocatedSize(of: url).bytes : nil
            items.append(HiddenItem(
                url: url, isFolder: isFolder, size: size, isHiddenByFlag: isFlagged, role: role,
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), root: URL(filePath: root)
            ))
        }
        return items.sorted { ($0.size ?? -1, $1.name) > ($1.size ?? -1, $0.name) }
    }

    /// Hidden items anywhere below the folder whose name contains `query`, ignoring case and accents, or that sit inside
    /// a hidden folder. Stops after `limit` items. Folders aren't measured, which keeps it quick.
    public func search(_ query: String, limit: Int = 500) -> [HiddenItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let root = PathUtilities.realPath(folder.path(percentEncoded: false)), let rootPath = strdup(root) else { return [] }
        defer { free(rootPath) }
        guard let stream = fts_open([rootPath, nil], FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return [] }
        defer { fts_close(stream) }
        let homePath = PathUtilities.realPath(home.path(percentEncoded: false)) ?? home.path(percentEncoded: false)

        var items: [HiddenItem] = []
        // The levels of the hidden folders being walked: everything below them counts as hidden too.
        var hiddenLevels: [Int] = []
        while let entry = fts_read(stream), items.count < limit, !Task.isCancelled {
            let level = Int(entry.pointee.fts_level)
            let kind = Int32(entry.pointee.fts_info)
            if kind == FTS_DP {
                if hiddenLevels.last == level { hiddenLevels.removeLast() }
                continue
            }
            guard level > 0, kind == FTS_D || kind == FTS_F || kind == FTS_SL || kind == FTS_SLNONE else { continue }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            let info = entry.pointee.fts_statp.pointee
            let isFlagged = info.st_flags & UInt32(UF_HIDDEN) != 0
            let insideHidden = hiddenLevels.contains { $0 < level }
            if kind == FTS_D {
                if Self.searchSkips.contains(name) || (root == homePath && level == 1 && name == "Library")
                    || LargeFileScanner.packageExtensions.contains((name as NSString).pathExtension.lowercased())
                    || info.st_flags & datalessFlag != 0 || safety.isExcluded(path: path) {
                    fts_set(stream, entry, FTS_SKIP)
                } else if name.hasPrefix(".") || isFlagged {
                    hiddenLevels.append(level)
                }
            }
            guard !Self.ignored.contains(name), name.hasPrefix(".") || isFlagged || insideHidden,
                  name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }
            let url = URL(filePath: path)
            items.append(HiddenItem(
                url: url, isFolder: kind == FTS_D, size: kind == FTS_D ? nil : Int64(info.st_blocks) * 512, isHiddenByFlag: isFlagged,
                role: role(of: url, name: name, in: (path as NSString).deletingLastPathComponent, home: homePath),
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), root: URL(filePath: root)
            ))
        }
        return items
    }

    private func role(of url: URL, name: String, in parent: String, home: String) -> HiddenItem.Role {
        let path = url.path(percentEncoded: false)
        // Inside a place for keys and passwords, or holding one, such as `~/.config` holding `~/.config/gh`.
        let holdsCredentials = SafetyPolicy.credentialPaths.map { home + "/" + $0 }.contains { credentials in
            if DuplicateScanner.isInside(path, credentials) { return true }
            var info = stat()
            return DuplicateScanner.isInside(credentials, path) && lstat(credentials, &info) == 0
        }
        if holdsCredentials { return .credentials }
        if Self.system.contains(name) || (parent == home && name == "Library") || !safety.acceptsItems(in: url) { return .system }
        return .other
    }
}

/// Finder's hidden flag, and Finder's setting to show every hidden item.
public enum HiddenFlag {
    /// Hides an item in Finder, or shows it again. A name starting with a dot keeps the item hidden either way.
    /// Protected locations, such as the system folders, are left alone.
    public static func setHidden(_ hidden: Bool, at url: URL, safety: SafetyGuard) throws {
        guard safety.acceptsItems(in: url) else { throw POSIXError(.EPERM) }
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
        let flags = hidden ? info.st_flags | UInt32(UF_HIDDEN) : info.st_flags & ~UInt32(UF_HIDDEN)
        guard lchflags(path, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
    }

    private static let finder = "com.apple.finder"
    private static let showAllFiles = "AppleShowAllFiles"

    /// Whether Finder shows hidden items in every window.
    public static var finderShowsHiddenItems: Bool {
        let value = CFPreferencesCopyAppValue(showAllFiles as CFString, finder as CFString)
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return ["yes", "true", "1"].contains(text.lowercased()) }
        return false
    }

    /// Changes Finder's setting and starts Finder again, since it reads the setting at launch. macOS opens Finder again
    /// on its own; its windows come back.
    @discardableResult
    public static func setFinderShowsHiddenItems(_ show: Bool) -> Bool {
        CFPreferencesSetAppValue(showAllFiles as CFString, show as CFBoolean, finder as CFString)
        guard CFPreferencesAppSynchronize(finder as CFString) else { return false }
        return LaunchControl.run(["Finder"], tool: "/usr/bin/killall").status == 0
    }
}
