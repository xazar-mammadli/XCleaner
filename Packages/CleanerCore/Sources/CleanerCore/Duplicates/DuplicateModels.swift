import Foundation

/// A file or folder whose content exists more than once.
public struct DuplicateItem: Sendable, Hashable, Identifiable {
    /// What an item looked like when it was found, to tell later whether it changed since.
    public struct Stamp: Sendable, Hashable {
        let device: Int64
        let inode: UInt64
        /// A file's length and change time, or a folder's names, sizes and change times condensed into one number.
        let contents: UInt64
    }

    public var id: URL { url }
    public let url: URL
    public let isFolder: Bool
    /// Space it takes on disk.
    public let size: Int64
    /// What removing it gives back. Less than `size` when it shares its storage with a clone, such as the copies
    /// Finder's Duplicate makes on APFS, or with a hard link.
    public let reclaimableSize: Int64
    /// The files it holds; 1 for a file.
    public let fileCount: Int
    public let modified: Date
    public let created: Date?
    /// The folder the scan looked in. The item must still be inside it when it is removed.
    public let root: URL
    public let stamp: Stamp

    public init(
        url: URL, isFolder: Bool, size: Int64, reclaimableSize: Int64, fileCount: Int, modified: Date, created: Date?, root: URL,
        stamp: Stamp
    ) {
        self.url = url
        self.isFolder = isFolder
        self.size = size
        self.reclaimableSize = reclaimableSize
        self.fileCount = fileCount
        self.modified = modified
        self.created = created
        self.root = root
        self.stamp = stamp
    }

    public var name: String { url.lastPathComponent }

    /// The device it lives on. Smart Select keeps a copy on each disk, since copies on another disk are often backups.
    public var device: Int64 { stamp.device }

    /// The item as one to remove. The user picked it, so it only ever goes to the Trash.
    public var cleanableItem: CleanableItem {
        CleanableItem(
            url: url, category: .duplicates, size: reclaimableSize, safety: .review, origin: .userSelection, root: root,
            date: modified, kind: isFolder ? nil : FileMetadata.kind(ofExtension: url.pathExtension)
        )
    }

    /// Whether `item` lies inside this folder.
    public func contains(_ item: DuplicateItem) -> Bool {
        isFolder && item.url != url
            && DuplicateScanner.isInside(item.url.path(percentEncoded: false), url.path(percentEncoded: false))
    }

    /// Whether it is still there, unchanged since the scan.
    public func isUnchanged() -> Bool {
        Self.stamp(at: url.path(percentEncoded: false), isFolder: isFolder) == stamp
    }

    static func stamp(at path: String, isFolder: Bool) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        guard isDirectory == isFolder, isDirectory || (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        if isFolder {
            guard let snapshot = FolderSnapshot.take(path) else { return nil }
            return Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), contents: snapshot.stamp)
        }
        return Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), contents: Shape.fileStamp(info))
    }
}

/// Copies of the same content: two or more files, or two or more folders.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// The content's SHA-256.
    public let id: String
    /// Ordered by path.
    public let items: [DuplicateItem]
    /// Bytes in each copy.
    public let length: Int64

    public init(id: String, items: [DuplicateItem], length: Int64) {
        self.id = id
        self.items = items
        self.length = length
    }

    public var isFolders: Bool { items.first?.isFolder ?? false }

    /// The name most copies carry, the shortest when it's a tie: "Report.pdf" rather than "Report copy.pdf".
    public var name: String {
        let counts = Dictionary(items.map { ($0.name, 1) }, uniquingKeysWith: +)
        return counts.min { first, second in
            (-first.value, first.key.count, first.key) < (-second.value, second.key.count, second.key)
        }?.key ?? ""
    }
    public var kind: FileKind? { isFolders ? nil : items.first.map { FileMetadata.kind(ofExtension: $0.url.pathExtension) } }
    /// Orders groups by the space their extra copies take, then by name, so the list doesn't reshuffle between scans.
    static func biggestWasteFirst(_ first: DuplicateGroup, _ second: DuplicateGroup) -> Bool {
        if first.extraSize != second.extraSize { return first.extraSize > second.extraSize }
        let order = first.name.localizedStandardCompare(second.name)
        return order == .orderedSame ? first.id < second.id : order == .orderedAscending
    }

    /// What removing every copy but the largest gives back.
    public var extraSize: Int64 {
        items.map(\.reclaimableSize).reduce(0, +) - (items.map(\.reclaimableSize).max() ?? 0)
    }
}

/// Two folders that share many files without being copies of each other, such as a folder and an older copy of it.
/// They can be merged into one.
public struct SimilarFolders: Sendable, Hashable, Identifiable {
    public var id: String { first.path(percentEncoded: false) + "\n" + second.path(percentEncoded: false) }
    public let first: URL
    public let second: URL
    /// Files found in both.
    public let sharedFiles: Int
    public let sharedBytes: Int64
    /// Files directly inside each folder.
    public let firstFiles: Int
    public let secondFiles: Int

    public init(first: URL, second: URL, sharedFiles: Int, sharedBytes: Int64, firstFiles: Int, secondFiles: Int) {
        self.first = first
        self.second = second
        self.sharedFiles = sharedFiles
        self.sharedBytes = sharedBytes
        self.firstFiles = firstFiles
        self.secondFiles = secondFiles
    }
}

public struct DuplicateScanResult: Sendable {
    /// Identical files, largest waste first. Files inside identical folders are left to `folderGroups`.
    public var fileGroups: [DuplicateGroup] = []
    /// Identical folders, largest waste first. Folders inside them are not listed again.
    public var folderGroups: [DuplicateGroup] = []
    public var similarFolders: [SimilarFolders] = []
    public var issues: Set<ScanIssue> = []

    public init() {}
}

public struct DuplicateScanProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Walking the folders.
        case looking
        /// Reading files of the same size to compare them.
        case comparing
    }

    public let stage: Stage
    public let filesSeen: Int
    public let bytesCompared: Int64
    public let bytesToCompare: Int64

    public var fraction: Double {
        bytesToCompare == 0 ? 0 : min(1, Double(bytesCompared) / Double(bytesToCompare))
    }
}
