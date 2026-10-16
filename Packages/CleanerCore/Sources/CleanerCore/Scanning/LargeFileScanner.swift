import Foundation

/// Walks the home folder for big files. It skips `~/Library`, hidden folders and packages such as apps
/// and photo libraries, and files that only exist in the cloud. Found files are the user's own,
/// so they are offered for review and only ever go to the Trash.
public struct LargeFileScanner: Sendable {
    public var minimumSize: Int64

    /// Packages are treated as single documents and never walked into.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "kext", "xpc", "photoslibrary", "photolibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj",
        "xcworkspace", "playground", "sparsebundle", "pages", "numbers", "key", "rtfd",
    ]

    public init(minimumSize: Int64 = 100_000_000) {
        self.minimumSize = minimumSize
    }

    /// `progress` receives the number of files looked at so far, every few thousand files.
    public func scan(_ context: ScanContext, progress: (@Sendable (Int) -> Void)? = nil) async -> ScanResult {
        var result = ScanResult()
        let home = PathUtilities.realPath(context.home.path(percentEncoded: false)) ?? context.home.path(percentEncoded: false)
        guard let rootPath = strdup(home) else { return result }
        defer { free(rootPath) }

        let roots: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let stream = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return result }
        defer { fts_close(stream) }

        var filesSeen = 0
        while let entry = fts_read(stream), !Task.isCancelled {
            switch Int32(entry.pointee.fts_info) {
            case FTS_D where entry.pointee.fts_level > 0:
                if shouldSkip(directory: entry, homeLevel: entry.pointee.fts_level == 1, context: context) {
                    fts_set(stream, entry, FTS_SKIP)
                }
            case FTS_F:
                filesSeen += 1
                if filesSeen % 5_000 == 0 { progress?(filesSeen) }
                let info = entry.pointee.fts_statp.pointee
                let bytes = Int64(info.st_blocks) * 512
                guard bytes >= minimumSize, info.st_flags & Self.dataless == 0 else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let url = URL(filePath: path)
                guard !url.lastPathComponent.hasPrefix("."), !context.safety.isExcluded(path: path) else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                result.items.append(CleanableItem(
                    url: url, category: .largeFiles, size: bytes, safety: .review, origin: .userSelection,
                    root: context.home, date: FileMetadata.lastUsedDate(atPath: path) ?? modified,
                    kind: FileMetadata.kind(ofExtension: url.pathExtension)
                ))
            case FTS_DNR, FTS_ERR:
                if entry.pointee.fts_errno == EPERM || entry.pointee.fts_errno == EACCES {
                    result.issues.insert(.accessDenied(String(cString: entry.pointee.fts_path)))
                }
            default:
                break
            }
        }
        progress?(filesSeen)
        result.items.sort { $0.size > $1.size }
        return result
    }

    private func shouldSkip(directory entry: UnsafeMutablePointer<FTSENT>, homeLevel: Bool, context: ScanContext) -> Bool {
        let path = String(cString: entry.pointee.fts_path)
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") || (homeLevel && name == "Library") { return true }
        if Self.packageExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        if entry.pointee.fts_statp.pointee.st_flags & Self.dataless != 0 { return true }
        return context.safety.isExcluded(path: path)
    }

    /// `SF_DATALESS`: the contents live in the cloud and take no space on this Mac.
    private static let dataless: UInt32 = 0x4000_0000
}
