import Foundation

/// Measures how much disk space a file or folder really takes.
public enum DirectorySizer {
    public struct Result: Sendable, Equatable {
        /// Allocated bytes on disk, not the logical file length.
        public var bytes: Int64 = 0
        public var fileCount = 0
        /// Entries that could not be read, usually for lack of permission.
        public var unreadableCount = 0
    }

    /// Never follows symlinks, never crosses into another volume, counts hard-linked files once,
    /// and skips cloud placeholder folders so that measuring them never triggers a download.
    public static func allocatedSize(of url: URL) -> Result {
        var result = Result()
        guard let path = strdup(url.path(percentEncoded: false)) else { return result }
        defer { free(path) }

        let roots: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let stream = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            result.unreadableCount += 1
            return result
        }
        defer { fts_close(stream) }

        var seenHardLinks = Set<HardLink>()
        while let entry = fts_read(stream), !Task.isCancelled {
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                if entry.pointee.fts_statp.pointee.st_flags & dataless != 0 {
                    fts_set(stream, entry, FTS_SKIP)
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let info = entry.pointee.fts_statp.pointee
                if info.st_nlink > 1, (info.st_mode & S_IFMT) == S_IFREG,
                   !seenHardLinks.insert(HardLink(device: info.st_dev, inode: info.st_ino)).inserted {
                    continue
                }
                result.bytes += Int64(info.st_blocks) * 512
                result.fileCount += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                result.unreadableCount += 1
            default:
                break
            }
        }
        return result
    }

    /// `SF_DATALESS`: the folder's contents live in the cloud and are not on this Mac.
    private static let dataless: UInt32 = 0x4000_0000

    private struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}
