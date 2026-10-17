import CryptoKit
import Foundation

/// Merges one folder into another. Files the kept folder already has, compared by content, go to the Trash; the others
/// move into it, at the same place inside; then the emptied folder goes to the Trash. Nothing is lost on the way: a
/// file only goes when an identical one stays, and a move never replaces anything.
public enum FolderMerger {
    public enum Refusal: Error, Sendable, Equatable {
        /// One of the folders is gone.
        case missing
        /// The folders are the same, or one is inside the other.
        case nested
        /// Moving between disks means copying, which is left to Finder.
        case differentDisks
        /// The folder to merge holds something other than plain files and folders: a link, a package such as an app,
        /// a hidden folder, or files kept in the cloud.
        case unsupportedItem(String)
        /// A protected or excluded location, which may not be changed this way.
        case protectedLocation
        /// A folder whose files can't be moved, such as one an app keeps read-only. Holds its path.
        case readOnly(String)
    }

    public struct Plan: Sendable {
        public struct Duplicate: Sendable {
            /// The file in the merged folder, which goes to the Trash.
            public let file: DuplicateItem
            /// Its identical twin in the kept folder, which stays.
            public let twin: DuplicateItem
        }

        public struct Move: Sendable {
            public let file: DuplicateItem
            public let destination: URL
        }

        public let keep: URL
        public let other: URL
        public let duplicates: [Duplicate]
        public let moves: [Move]

        public var duplicateBytes: Int64 { duplicates.reduce(0) { $0 + $1.file.reclaimableSize } }
        public var movedBytes: Int64 { moves.reduce(0) { $0 + $1.file.size } }
    }

    public struct Report: Sendable {
        public struct Moved: Sendable {
            public let from: URL
            public let to: URL
        }

        public struct Failure: Sendable {
            public let url: URL
            public let message: String
        }

        public let method: DeletionMethod
        public internal(set) var moved: [Moved] = []
        public internal(set) var failures: [Failure] = []
        /// The files that went because the kept folder has them.
        public internal(set) var duplicates: CleaningReport
        /// The emptied folder, once it went.
        public internal(set) var folder: CleaningReport?
        /// Files still in the merged folder afterwards, which kept it from going.
        public internal(set) var filesLeft = 0

        init(method: DeletionMethod) {
            self.method = method
            duplicates = CleaningReport(requestedMethod: method)
        }
    }

    /// Looks at both folders and works out what would happen, without changing anything.
    public static func plan(keep: URL, other: URL, safety: SafetyGuard) -> Result<Plan, Refusal> {
        guard let keepPath = PathUtilities.realPath(keep.path(percentEncoded: false)),
              let otherPath = PathUtilities.realPath(other.path(percentEncoded: false)),
              let keepInfo = folderInfo(keepPath), let otherInfo = folderInfo(otherPath)
        else { return .failure(.missing) }
        guard !DuplicateScanner.isInside(keepPath, otherPath), !DuplicateScanner.isInside(otherPath, keepPath) else {
            return .failure(.nested)
        }
        guard keepInfo.st_dev == otherInfo.st_dev else { return .failure(.differentDisks) }
        let otherURL = URL(filePath: otherPath)
        let keepURL = URL(filePath: keepPath)
        guard case .allowed = safety.evaluate(otherURL, origin: .userSelection, root: otherURL.deletingLastPathComponent()),
              safety.acceptsItems(in: keepURL)
        else { return .failure(.protectedLocation) }

        guard let source = FolderSnapshot.take(otherPath) else { return .failure(.unsupportedItem(otherPath)) }
        if let item = source.unsupported { return .failure(.unsupportedItem(item)) }
        // Files move out of every folder of the merged one, into the kept one, and the emptied folder leaves its parent.
        let writable = [keepPath, otherPath, (otherPath as NSString).deletingLastPathComponent] + source.folders.map { otherPath + "/" + $0 }
        if let folder = writable.first(where: { access($0, W_OK) != 0 }) { return .failure(.readOnly(folder)) }
        guard let target = FolderSnapshot.take(keepPath) else { return .failure(.unsupportedItem(keepPath)) }

        // Only plain files count as twins: not ones inside packages or hidden folders of the kept folder.
        let twins = Dictionary(grouping: target.files.filter { isPlain($0.relativePath) }, by: \.length)
        var digests: [String: SHA256Digest] = [:]
        func digest(_ path: String) -> SHA256Digest? {
            if let known = digests[path] { return known }
            let digest = ContentHasher.digest(atPath: path)
            digests[path] = digest
            return digest
        }

        var duplicates: [Plan.Duplicate] = []
        var moves: [Plan.Move] = []
        var places = Places(root: keepPath)
        for file in source.files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let candidates = twins[file.length] ?? []
            if !candidates.isEmpty, let content = digest(file.path), let twin = candidates.first(where: { digest($0.path) == content }) {
                duplicates.append(.init(file: item(file, root: otherURL), twin: item(twin, root: keepURL)))
            } else {
                moves.append(.init(file: item(file, root: otherURL), destination: URL(filePath: places.destination(for: file.relativePath))))
            }
        }
        return .success(Plan(keep: keepURL, other: otherURL, duplicates: duplicates, moves: moves))
    }

    /// Carries out `plan`, checking each file again first. A test run changes nothing and reports what would happen.
    public static func merge(_ plan: Plan, cleaner: Cleaner, method: DeletionMethod) async -> Report {
        var report = Report(method: method)

        // A file goes only while its twin is still there, unchanged.
        var trashable: [CleanableItem] = []
        for duplicate in plan.duplicates {
            if duplicate.file.isUnchanged(), duplicate.twin.isUnchanged() {
                trashable.append(duplicate.file.cleanableItem)
            } else {
                report.failures.append(.init(url: duplicate.file.url, message: "changedSinceScan"))
            }
        }
        report.duplicates = await cleaner.clean(trashable, method: method)

        for move in plan.moves {
            guard !Task.isCancelled else { break }
            guard move.file.isUnchanged(),
                  case .allowed(let path, _) = cleaner.safety.evaluate(move.file.url, origin: .userSelection, root: plan.other)
            else {
                report.failures.append(.init(url: move.file.url, message: "changedSinceScan"))
                continue
            }
            if method == .dryRun {
                report.moved.append(.init(from: move.file.url, to: move.destination))
                await cleaner.auditLog?.record(.init(
                    action: .dryRun, path: path, bytes: move.file.size, detail: "moveTo:" + move.destination.path(percentEncoded: false)
                ))
                continue
            }
            do {
                try FileManager.default.createDirectory(at: move.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let destination = try moveWithoutReplacing(path, to: move.destination.path(percentEncoded: false))
                report.moved.append(.init(from: move.file.url, to: URL(filePath: destination)))
                await cleaner.auditLog?.record(.init(action: .moved, path: path, bytes: move.file.size, detail: destination))
            } catch {
                report.failures.append(.init(url: move.file.url, message: error.localizedDescription))
                await cleaner.auditLog?.record(.init(action: .failed, path: path, bytes: move.file.size, detail: error.localizedDescription))
            }
        }

        let folder = { (size: Int64) in
            CleanableItem(
                url: plan.other, category: .duplicates, size: size, safety: .review, origin: .userSelection,
                root: plan.other.deletingLastPathComponent()
            )
        }
        if method == .dryRun {
            report.folder = await cleaner.clean([folder(0)], method: .dryRun)
        } else if let left = FolderSnapshot.take(plan.other.path(percentEncoded: false)), left.files.isEmpty, left.unsupported == nil {
            report.folder = await cleaner.clean([folder(left.allocated)], method: method)
        } else {
            report.filesLeft = FolderSnapshot.take(plan.other.path(percentEncoded: false))?.files.count ?? 0
        }
        return report
    }

    /// Renames `path` to `destination`, or to "Name 2", "Name 3"… next to it when that is taken. The rename fails
    /// rather than replace anything, even when another app creates the name in between.
    static func moveWithoutReplacing(_ path: String, to destination: String) throws -> String {
        var places = Places(root: (destination as NSString).deletingLastPathComponent)
        var candidate = destination
        for _ in 0..<1_000 {
            if renamex_np(path, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            candidate = places.destination(for: (destination as NSString).lastPathComponent)
        }
        throw POSIXError(.EEXIST)
    }

    private static func item(_ file: FolderSnapshot.File, root: URL) -> DuplicateItem {
        var info = stat()
        _ = lstat(file.path, &info)
        return DuplicateItem(
            url: URL(filePath: file.path), isFolder: false, size: file.allocated,
            reclaimableSize: ContentHasher.reclaimableSize(atPath: file.path, allocated: file.allocated, links: file.links),
            fileCount: 1, modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            created: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)), root: root,
            stamp: .init(device: file.device, inode: file.inode, contents: file.stamp)
        )
    }

    /// Not inside a hidden folder or a package.
    private static func isPlain(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().allSatisfy { name in
            !name.hasPrefix(".") && !DuplicateScanner.packageExtensions.contains((String(name) as NSString).pathExtension.lowercased())
        }
    }

    private static func folderInfo(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return info
    }
}

/// Free places inside a folder: the same relative path when nothing is there, or the first free "Name 2", "Name 3"…
/// A file is never put where a folder is needed, nor the other way round.
struct Places {
    let root: String
    /// Places already given out, so two files never get the same one.
    private var taken = Set<String>()
    /// Where each subfolder of the source ends up.
    private var folders: [String: String] = [:]

    init(root: String) {
        self.root = root
    }

    mutating func destination(for relativePath: String) -> String {
        let parts = relativePath.split(separator: "/").map(String.init)
        var folder = root
        var source = ""
        for name in parts.dropLast() {
            source += "/" + name
            if let known = folders[source] {
                folder = known
                continue
            }
            folder = free(name, in: folder, asFolder: true)
            folders[source] = folder
        }
        return free(parts.last ?? relativePath, in: folder, asFolder: false)
    }

    private mutating func free(_ name: String, in folder: String, asFolder: Bool) -> String {
        let stem = asFolder ? name : (name as NSString).deletingPathExtension
        let pathExtension = asFolder ? "" : (name as NSString).pathExtension
        var number = 1
        while true {
            let candidateName = number == 1 ? name : "\(stem) \(number)" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            let candidate = folder + "/" + candidateName
            number += 1
            var info = stat()
            let exists = lstat(candidate, &info) == 0
            if asFolder {
                // A folder that is already there, or one planned for this merge, takes more files.
                if taken.contains(candidate) || (exists && (info.st_mode & S_IFMT) != S_IFDIR) { continue }
                if exists || folders.values.contains(candidate) { return candidate }
                taken.insert(candidate)
                return candidate
            }
            guard !exists, !taken.contains(candidate), !folders.values.contains(candidate) else { continue }
            taken.insert(candidate)
            return candidate
        }
    }
}
