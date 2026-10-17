import CryptoKit
import Foundation

/// Finds files, and folders, whose content exists more than once in the folders the user picks.
///
/// Files are compared in three steps, each reading more than the last but for fewer files: by size, by a hash of their
/// first and last bytes, and by a SHA-256 of all their content. Folders are compared by their names and file sizes
/// first, then by the content of every file inside. Like the big-file finder, it leaves out `~/Library`, hidden folders,
/// packages such as apps and photo libraries, files kept in the cloud, and folders of downloaded dependencies, which
/// hold duplicates on purpose. Neither are copies offered that can't be moved: those in read-only folders.
public struct DuplicateScanner: Sendable {
    public var folders: [URL]
    /// Smaller files are left out of the file list. Folders are compared with all their files.
    public var minimumSize: Int64

    static let packageExtensions = LargeFileScanner.packageExtensions
    /// Downloaded dependencies and build output. Projects keep the same files in them on purpose.
    static let skippedFolderNames: Set<String> = [
        "node_modules", "bower_components", "Pods", "Carthage", "DerivedData", "__pycache__", "site-packages", "vendor",
    ]
    /// Smaller folders aren't worth listing.
    static let minimumFolderSize: Int64 = 1_000_000
    /// A file copied more often than this, such as a license text, says nothing about which folders belong together.
    static let similarityCopyLimit = 20
    /// Folders count as similar when at least this share of the files in the fuller one is in both.
    static let similarityThreshold = 0.5

    public init(folders: [URL], minimumSize: Int64 = 1_000_000) {
        self.folders = folders
        self.minimumSize = minimumSize
    }

    public func scan(_ context: ScanContext, progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil) async -> DuplicateScanResult {
        var walk = Walk(minimumSize: minimumSize, folderMinimum: max(minimumSize, Self.minimumFolderSize), progress: progress)
        for root in Self.roots(folders, home: context.home) {
            walk.run(root, context: context)
            if Task.isCancelled { return DuplicateScanResult() }
        }

        var comparison = Comparison(filesSeen: walk.filesSeen, progress: progress)
        let groups = comparison.groupFiles(walk.files)
        if Task.isCancelled { return DuplicateScanResult() }

        var result = DuplicateScanResult()
        result.issues = walk.issues
        result.folderGroups = comparison.groupFolders(walk.folders)
        if Task.isCancelled { return DuplicateScanResult() }
        let copied = result.folderGroups.flatMap(\.items).map { $0.url.path(percentEncoded: false) }
        // A file inside folders that are copies of each other is listed with its folder.
        result.fileGroups = groups
            .filter { group in !group.items.allSatisfy { item in copied.contains { Self.isInside(item.url.path(percentEncoded: false), $0) } } }
            .sorted(by: DuplicateGroup.biggestWasteFirst)
        result.similarFolders = Self.similarFolders(in: groups, directFiles: walk.directFiles, excluding: copied)
        return result
    }

    // MARK: - Where to look

    struct Root {
        let path: String
        let url: URL
        let isHome: Bool
    }

    /// The folders to walk, canonical, each once. A folder inside another one is dropped, unless walking the outer one
    /// would skip it, as it skips `~/Library` and hidden folders.
    static func roots(_ folders: [URL], home: URL) -> [Root] {
        let homePath = PathUtilities.realPath(home.path(percentEncoded: false)) ?? home.path(percentEncoded: false)
        let paths = Set(folders.compactMap { PathUtilities.realPath($0.path(percentEncoded: false)) }).sorted()
        var kept: [String] = []
        for path in paths where !kept.contains(where: { reaches($0, path, home: homePath) }) {
            kept.append(path)
        }
        return kept.map { Root(path: $0, url: URL(filePath: $0), isHome: $0 == homePath) }
    }

    /// Whether walking `parent` reaches `child`.
    static func reaches(_ parent: String, _ child: String, home: String) -> Bool {
        guard isInside(child, parent) else { return false }
        let between = child.dropFirst(parent.count).split(separator: "/").map(String.init)
        return !between.enumerated().contains { offset, name in
            let above = offset == 0 ? (parent as NSString).lastPathComponent : between[offset - 1]
            return skips(folderNamed: name, inFolderNamed: above, level: offset + 1, rootIsHome: parent == home)
        }
    }

    static func skips(folderNamed name: String, inFolderNamed parent: String, level: Int, rootIsHome: Bool) -> Bool {
        name.hasPrefix(".") || (rootIsHome && level == 1 && name == "Library")
            || packageExtensions.contains((name as NSString).pathExtension.lowercased()) || skippedFolderNames.contains(name)
            // Go's module cache, `~/go/pkg/mod`: Go keeps it read-only and checks it against records of its own.
            || (name == "mod" && parent == "pkg")
    }

    /// Whether `path` is `folder` or lies inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    // MARK: - Similar folders

    /// Pairs of folders, neither inside the other, that share at least half the files of the fuller one. Only pairs on
    /// one disk count: merging moves files, and copies on another disk are usually backups.
    static func similarFolders(in groups: [DuplicateGroup], directFiles: [String: Int], excluding copied: [String]) -> [SimilarFolders] {
        struct Pair: Hashable {
            let first: String
            let second: String
        }
        var shared: [Pair: (files: Int, bytes: Int64)] = [:]
        for group in groups where group.items.count <= similarityCopyLimit {
            // The folders holding a copy, and the disk each is on.
            var parents: [String: Int64] = [:]
            for item in group.items {
                parents[(item.url.path(percentEncoded: false) as NSString).deletingLastPathComponent] = item.device
            }
            let folders = parents.keys.sorted()
            for (index, first) in folders.enumerated() {
                for second in folders[(index + 1)...]
                where parents[first] == parents[second] && !isInside(first, second) && !isInside(second, first) {
                    shared[Pair(first: first, second: second), default: (0, 0)].files += 1
                    shared[Pair(first: first, second: second), default: (0, 0)].bytes += group.length
                }
            }
        }
        return shared.compactMap { pair, count -> SimilarFolders? in
            let firstFiles = directFiles[pair.first] ?? 0
            let secondFiles = directFiles[pair.second] ?? 0
            guard count.files >= 2, firstFiles > 0, secondFiles > 0,
                  Double(count.files) / Double(max(firstFiles, secondFiles)) >= similarityThreshold,
                  !copied.contains(where: { isInside(pair.first, $0) || isInside(pair.second, $0) })
            else { return nil }
            return SimilarFolders(
                first: URL(filePath: pair.first), second: URL(filePath: pair.second),
                sharedFiles: count.files, sharedBytes: count.bytes, firstFiles: firstFiles, secondFiles: secondFiles
            )
        }
        .sorted { $0.sharedBytes == $1.sharedBytes ? $0.id < $1.id : $0.sharedBytes > $1.sharedBytes }
        .prefix(100)
        .map { $0 }
    }
}

// MARK: - Walking the folders

private struct FileKey: Hashable {
    let device: Int64
    let inode: UInt64
}

/// A file big enough to compare.
private struct Candidate {
    let path: String
    let root: URL
    let length: Int64
    let allocated: Int64
    let links: UInt16
    let key: FileKey
    let stamp: UInt64
    let modified: Date
    let created: Date?
}

/// A folder big enough to compare, and made of plain files and folders only.
private struct FolderCandidate {
    let path: String
    let root: URL
    let shape: UInt64
    let length: Int64
    let fileCount: Int
    let depth: Int
    let modified: Date
    let created: Date?
}

/// One walk over the chosen folders, collecting files to compare and the shape of every folder.
private struct Walk {
    let minimumSize: Int64
    let folderMinimum: Int64
    let progress: (@Sendable (DuplicateScanProgress) -> Void)?
    var files: [Candidate] = []
    var folders: [FolderCandidate] = []
    /// Visible files directly inside each folder, by path.
    var directFiles: [String: Int] = [:]
    var issues: Set<ScanIssue> = []
    var filesSeen = 0
    /// Hard links are one file under several names; only the first name counts.
    private var seen = Set<FileKey>()

    init(minimumSize: Int64, folderMinimum: Int64, progress: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.minimumSize = minimumSize
        self.folderMinimum = folderMinimum
        self.progress = progress
    }

    /// A folder being walked.
    private struct Frame {
        let path: String
        let name: String
        let depth: Int
        let info: stat
        /// Whether items in it can be moved, which taking them to the Trash needs.
        let isWritable: Bool
        /// Whether `SafetyGuard` lets anything inside go, worked out once the first file asks.
        var allowsRemoval: Bool?
        var shape = Shape.Accumulator()
        var length: Int64 = 0
        var allocated: Int64 = 0
        var fileCount = 0
        var directFiles = 0
        /// False once it holds anything but plain files and folders, or something the walk skips: such a folder is
        /// never offered as a copy, since removing it would take along things nobody compared.
        var isPlain = true
    }

    mutating func run(_ root: DuplicateScanner.Root, context: ScanContext) {
        guard let rootPath = strdup(root.path) else { return }
        defer { free(rootPath) }
        guard let stream = fts_open([rootPath, nil], FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }

        var frames: [Frame] = []
        var rootDevice: dev_t = 0
        while let entry = fts_read(stream), !Task.isCancelled {
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            let level = Int(entry.pointee.fts_level)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let info = entry.pointee.fts_statp.pointee
                if level == 0 {
                    rootDevice = info.st_dev
                } else if DuplicateScanner.skips(
                    folderNamed: name, inFolderNamed: frames[frames.count - 1].name, level: level, rootIsHome: root.isHome
                ) || info.st_flags & datalessFlag != 0 || info.st_dev != rootDevice || context.safety.isExcluded(path: path) {
                    fts_set(stream, entry, FTS_SKIP)
                    frames[frames.count - 1].isPlain = false
                    continue
                }
                frames.append(Frame(path: path, name: name, depth: level, info: info, isWritable: access(path, W_OK) == 0))
            case FTS_DP:
                // A skipped folder comes back here without a frame of its own.
                guard frames.last?.path == path, let frame = frames.popLast() else { continue }
                // A folder that was looked in isn't offered itself, and moving a folder to the Trash needs write access
                // to it and to the folder holding it.
                let isMovable = level > 0 && frame.isWritable && frames.last?.isWritable == true
                finish(frame, root: root.url, isMovable: isMovable, context: context)
                if !frames.isEmpty {
                    frames[frames.count - 1].shape.add(name: frame.name, frame.shape.signature)
                    frames[frames.count - 1].length += frame.length
                    frames[frames.count - 1].allocated += frame.allocated
                    frames[frames.count - 1].fileCount += frame.fileCount
                    frames[frames.count - 1].isPlain = frames[frames.count - 1].isPlain && frame.isPlain
                }
            case FTS_F:
                guard let folder = frames.last, name != ".DS_Store" else { continue }
                let info = entry.pointee.fts_statp.pointee
                guard info.st_flags & datalessFlag == 0, !context.safety.isExcluded(path: path) else {
                    frames[frames.count - 1].isPlain = false
                    continue
                }
                let length = Int64(info.st_size)
                let allocated = Int64(info.st_blocks) * 512
                frames[frames.count - 1].shape.add(name: name, Shape.file(length: length))
                frames[frames.count - 1].length += length
                frames[frames.count - 1].allocated += allocated
                frames[frames.count - 1].fileCount += 1
                let isHidden = name.hasPrefix(".")
                if !isHidden { frames[frames.count - 1].directFiles += 1 }
                filesSeen += 1
                if filesSeen % 5_000 == 0 {
                    progress?(.init(stage: .looking, filesSeen: filesSeen, bytesCompared: 0, bytesToCompare: 0))
                }
                let key = FileKey(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                guard length >= minimumSize, !isHidden, folder.isWritable else { continue }
                if folder.allowsRemoval == nil {
                    frames[frames.count - 1].allowsRemoval = context.safety.acceptsItems(in: URL(filePath: folder.path))
                }
                guard frames[frames.count - 1].allowsRemoval == true, seen.insert(key).inserted else { continue }
                files.append(Candidate(
                    path: path, root: root.url, length: length, allocated: allocated, links: UInt16(info.st_nlink), key: key,
                    stamp: Shape.fileStamp(info), modified: Self.date(info.st_mtimespec), created: Self.date(info.st_birthtimespec)
                ))
            case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if !frames.isEmpty { frames[frames.count - 1].isPlain = false }
            case FTS_DNR, FTS_ERR, FTS_NS:
                let error = entry.pointee.fts_errno
                if error == EPERM || error == EACCES { issues.insert(.accessDenied(path)) }
                // An unreadable folder comes back here instead of in post-order.
                if frames.last?.path == path { frames.removeLast() }
                if !frames.isEmpty { frames[frames.count - 1].isPlain = false }
            default:
                break
            }
        }
    }

    private mutating func finish(_ frame: Frame, root: URL, isMovable: Bool, context: ScanContext) {
        if frame.directFiles > 0 { directFiles[frame.path] = frame.directFiles }
        guard frame.isPlain, isMovable, frame.fileCount > 0, frame.allocated >= folderMinimum else { return }
        // Never folders such as Documents or Pictures themselves, nor anything else that may not go.
        let url = URL(filePath: frame.path)
        guard case .allowed = context.safety.evaluate(url, origin: .userSelection, root: url.deletingLastPathComponent()) else { return }
        folders.append(FolderCandidate(
            path: frame.path, root: root, shape: frame.shape.signature, length: frame.length, fileCount: frame.fileCount,
            depth: frame.depth, modified: Self.date(frame.info.st_mtimespec), created: Self.date(frame.info.st_birthtimespec)
        ))
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

// MARK: - Comparing content

/// Reads the files that might be copies, and keeps every full hash it computes for the folder comparison.
private struct Comparison {
    let filesSeen: Int
    let progress: (@Sendable (DuplicateScanProgress) -> Void)?
    private var digests: [FileKey: SHA256Digest] = [:]
    private var compared: Int64 = 0
    private var toCompare: Int64 = 0
    private var reported: Int64 = 0

    init(filesSeen: Int, progress: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.filesSeen = filesSeen
        self.progress = progress
    }

    mutating func groupFiles(_ files: [Candidate]) -> [DuplicateGroup] {
        let sameSize = Dictionary(grouping: files, by: \.length).values.filter { $0.count > 1 }
        toCompare = sameSize.reduce(0) { total, files in total + files.reduce(0) { $0 + $1.length } }
        report(force: true)

        var groups: [DuplicateGroup] = []
        for files in sameSize {
            guard !Task.isCancelled else { return [] }
            let length = files[0].length
            var bySample: [SHA256Digest: [Candidate]] = [:]
            for file in files {
                if let sample = ContentHasher.sample(atPath: file.path, length: length) { bySample[sample, default: []].append(file) }
            }
            for (sample, files) in bySample {
                // A small file was read whole, so its sample is its hash.
                if length <= Int64(ContentHasher.sampleLength * 2) {
                    advance(by: length * Int64(files.count))
                    if files.count > 1 { groups.append(group(files, digest: sample, length: length)) }
                    continue
                }
                guard files.count > 1 else {
                    advance(by: length)
                    continue
                }
                var byDigest: [SHA256Digest: [Candidate]] = [:]
                for file in files {
                    guard let digest = fullDigest(of: file.path, key: file.key) else { continue }
                    byDigest[digest, default: []].append(file)
                }
                for (digest, copies) in byDigest where copies.count > 1 {
                    groups.append(group(copies, digest: digest, length: length))
                }
            }
        }
        report(force: true)
        return groups
    }

    /// Folders that are copies of each other, biggest first. A folder inside one already found isn't listed again.
    mutating func groupFolders(_ folders: [FolderCandidate]) -> [DuplicateGroup] {
        struct Key: Hashable {
            let shape: UInt64
            let length: Int64
            let fileCount: Int
        }
        // Biggest first, and outer folders before inner ones of the same size, so a folder found as a copy hides
        // the copies inside it.
        let candidates: [[FolderCandidate]] = Dictionary(grouping: folders) {
            Key(shape: $0.shape, length: $0.length, fileCount: $0.fileCount)
        }
        .values.filter { $0.count > 1 }
        .map { $0.sorted { $0.depth < $1.depth } }
        .sorted { first, second in
            if first[0].length != second[0].length { return first[0].length > second[0].length }
            return first[0].depth < second[0].depth
        }

        var groups: [DuplicateGroup] = []
        var found: [String] = []
        for candidates in candidates {
            guard !Task.isCancelled else { return [] }
            let members = candidates.filter { folder in !found.contains { DuplicateScanner.isInside(folder.path, $0) } }
            guard members.count > 1 else { continue }
            var byContent: [SHA256Digest: [DuplicateItem]] = [:]
            for folder in members {
                guard let (digest, item) = verify(folder) else { continue }
                byContent[digest, default: []].append(item)
            }
            for (digest, copies) in byContent where copies.count > 1 {
                groups.append(DuplicateGroup(
                    id: digest.hex, items: copies.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) },
                    length: candidates[0].length
                ))
                found += copies.map { $0.url.path(percentEncoded: false) }
            }
        }
        return groups.sorted(by: DuplicateGroup.biggestWasteFirst)
    }

    /// Reads every file of the folder: the hash of their names and contents, and the folder as an item.
    private mutating func verify(_ folder: FolderCandidate) -> (SHA256Digest, DuplicateItem)? {
        guard let snapshot = FolderSnapshot.take(folder.path), snapshot.unsupported == nil, snapshot.shape == folder.shape,
              let info = Self.info(folder.path)
        else { return nil }
        var hasher = SHA256()
        var reclaimable: Int64 = 0
        for file in snapshot.files.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard let digest = fullDigest(of: file.path, key: FileKey(device: file.device, inode: file.inode)) else { return nil }
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(digest))
            reclaimable += ContentHasher.reclaimableSize(atPath: file.path, allocated: file.allocated, links: file.links)
        }
        let item = DuplicateItem(
            url: URL(filePath: folder.path), isFolder: true, size: snapshot.allocated,
            reclaimableSize: reclaimable, fileCount: snapshot.files.count, modified: folder.modified, created: folder.created,
            root: folder.root, stamp: .init(device: Int64(info.st_dev), inode: UInt64(info.st_ino), contents: snapshot.stamp)
        )
        return (hasher.finalize(), item)
    }

    private mutating func fullDigest(of path: String, key: FileKey) -> SHA256Digest? {
        if let known = digests[key] { return known }
        var read: Int64 = 0
        let digest = ContentHasher.digest(atPath: path) { read += Int64($0) }
        advance(by: read)
        if let digest { digests[key] = digest }
        return digest
    }

    private func group(_ files: [Candidate], digest: SHA256Digest, length: Int64) -> DuplicateGroup {
        let items = files.map { file in
            DuplicateItem(
                url: URL(filePath: file.path), isFolder: false, size: file.allocated,
                reclaimableSize: ContentHasher.reclaimableSize(atPath: file.path, allocated: file.allocated, links: file.links),
                fileCount: 1, modified: file.modified, created: file.created, root: file.root,
                stamp: .init(device: file.key.device, inode: file.key.inode, contents: file.stamp)
            )
        }
        return DuplicateGroup(
            id: digest.hex, items: items.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }, length: length
        )
    }

    private mutating func advance(by bytes: Int64) {
        compared += bytes
        report(force: false)
    }

    /// Reports at most every 32 MB, so the interface isn't flooded.
    private mutating func report(force: Bool) {
        guard force || compared - reported >= 32 << 20 else { return }
        reported = compared
        progress?(.init(stage: .comparing, filesSeen: filesSeen, bytesCompared: compared, bytesToCompare: toCompare))
    }

    private static func info(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
}

extension SHA256Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
