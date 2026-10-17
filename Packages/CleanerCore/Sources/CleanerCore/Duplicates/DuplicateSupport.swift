import CryptoKit
import Foundation

/// Reads files to compare what is in them.
enum ContentHasher {
    /// Bytes read from each end of a file for the quick first comparison.
    static let sampleLength = 16 * 1024
    static let chunkLength = 1 << 20

    /// A hash of a file's first and last bytes. Files that differ there need no full read.
    static func sample(atPath path: String, length: Int64) -> SHA256Digest? {
        withFile(path) { descriptor in
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: sampleLength)
            guard let head = read(descriptor, into: &buffer, at: 0) else { return nil }
            hasher.update(data: buffer[..<head])
            if length > Int64(sampleLength * 2) {
                guard let tail = read(descriptor, into: &buffer, at: length - Int64(sampleLength)) else { return nil }
                hasher.update(data: buffer[..<tail])
            }
            return hasher.finalize()
        }
    }

    /// The SHA-256 of the whole file, or nil when it can't be read or the task is cancelled.
    /// `onRead` hears how many bytes each read brought in.
    static func digest(atPath path: String, onRead: ((Int) -> Void)? = nil) -> SHA256Digest? {
        withFile(path) { descriptor in
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: chunkLength)
            while true {
                if Task.isCancelled { return nil }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, chunkLength) }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { break }
                hasher.update(data: buffer[..<count])
                onRead?(count)
            }
            return hasher.finalize()
        }
    }

    /// Opens without following a symlink, and asks macOS not to keep what is read in memory: a scan reads far more
    /// than is worth caching.
    private static func withFile<T>(_ path: String, _ body: (Int32) -> T?) -> T? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return body(descriptor)
    }

    /// Fills `buffer` from `offset` on, or up to the end of the file. Returns how many bytes came in.
    private static func read(_ descriptor: Int32, into buffer: inout [UInt8], at offset: Int64) -> Int? {
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress! + total, $0.count - total, off_t(offset) + off_t(total))
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            total += count
        }
        return total
    }

    /// The bytes on disk only this file holds: on APFS, a clone shares its storage with the file it was cloned from,
    /// so removing it frees only what changed since. Nil where the disk doesn't say.
    static func privateSize(atPath path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        // With FSOPT_ATTR_CMN_EXTENDED, the fork attributes are read as extended common attributes.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        // Laid out as: the length, the attributes returned, then the private size.
        return buffer.withUnsafeBytes { raw -> Int64? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }

    /// What removing a file frees: nothing for a hard link, whose content stays under its other name.
    static func reclaimableSize(atPath path: String, allocated: Int64, links: UInt16) -> Int64 {
        guard links <= 1 else { return 0 }
        return min(allocated, privateSize(atPath: path) ?? allocated)
    }
}

/// Condenses a folder's names and file sizes into one number. Entries are combined in a way that doesn't depend on
/// the order they are listed in, so two copies of a folder come out the same however the disk lists them.
enum Shape {
    struct Accumulator {
        private var sum: UInt64 = 0
        private var count: UInt64 = 0

        mutating func add(name: String, _ signature: UInt64) {
            sum &+= mix(nameHash(name) ^ mix(signature))
            count += 1
        }

        var signature: UInt64 { mix(sum ^ mix(count &+ 0x666F_6C64)) }
    }

    static func file(length: Int64) -> UInt64 {
        mix(UInt64(bitPattern: length) ^ 0x6669_6C65)
    }

    /// A file's length and when it last changed: any edit changes it.
    static func fileStamp(_ info: stat) -> UInt64 {
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
        return mix(file(length: Int64(info.st_size)) ^ mix(UInt64(bitPattern: nanoseconds)))
    }

    /// A link, a socket or anything else that is neither a plain file nor a folder.
    static let special: UInt64 = mix(0x7370_6563_6961_6C)

    /// FNV-1a over the name's bytes.
    static func nameHash(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// SplitMix64's finalizer: spreads every input bit over the whole output.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Everything inside a folder, read in one walk: its files, and its shape and stamp to compare it and to notice changes.
struct FolderSnapshot {
    struct File {
        let relativePath: String
        let path: String
        let length: Int64
        let allocated: Int64
        let device: Int64
        let inode: UInt64
        let links: UInt16
        let stamp: UInt64
    }

    var files: [File] = []
    /// Subfolders, relative to the folder.
    var folders: [String] = []
    /// Names and file sizes, as `DuplicateScanner` condenses them.
    var shape: UInt64 = 0
    /// Names, file sizes and change times.
    var stamp: UInt64 = 0
    /// The first item that isn't a plain file or folder: a link, a package, a hidden folder or a file kept in the cloud.
    var unsupported: String?

    var allocated: Int64 { files.reduce(0) { $0 + $1.allocated } }
    var length: Int64 { files.reduce(0) { $0 + $1.length } }

    /// Nil when the path is no folder, or when something inside can't be read: then nothing can be vouched for.
    static func take(_ root: String) -> FolderSnapshot? {
        guard let rootPath = strdup(root) else { return nil }
        defer { free(rootPath) }
        guard let stream = fts_open([rootPath, nil], FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }

        var snapshot = FolderSnapshot()
        var frames: [(path: String, name: String, shape: Shape.Accumulator, stamp: Shape.Accumulator)] = []
        var rootDevice: dev_t = 0
        while let entry = fts_read(stream) {
            if Task.isCancelled { return nil }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            let level = entry.pointee.fts_level
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let info = entry.pointee.fts_statp.pointee
                if level == 0 {
                    rootDevice = info.st_dev
                } else {
                    let isPackage = DuplicateScanner.packageExtensions.contains((name as NSString).pathExtension.lowercased())
                    if name.hasPrefix(".") || isPackage { snapshot.unsupported = snapshot.unsupported ?? path }
                    if info.st_flags & datalessFlag != 0 || info.st_dev != rootDevice {
                        // Its contents aren't on this disk. It counts as an item of its own, unopened.
                        snapshot.unsupported = snapshot.unsupported ?? path
                        fts_set(stream, entry, FTS_SKIP)
                        frames[frames.count - 1].shape.add(name: name, Shape.special)
                        frames[frames.count - 1].stamp.add(name: name, Shape.special)
                        continue
                    }
                    snapshot.folders.append(relative(path, in: root))
                }
                frames.append((path, name, .init(), .init()))
            case FTS_DP:
                // A skipped folder comes back here without a frame of its own.
                guard frames.last?.path == path, let frame = frames.popLast() else { continue }
                if frames.isEmpty {
                    snapshot.shape = frame.shape.signature
                    snapshot.stamp = frame.stamp.signature
                } else {
                    frames[frames.count - 1].shape.add(name: frame.name, frame.shape.signature)
                    frames[frames.count - 1].stamp.add(name: frame.name, frame.stamp.signature)
                }
            case FTS_F:
                guard !frames.isEmpty else { return nil }
                guard name != ".DS_Store" else { continue }
                let info = entry.pointee.fts_statp.pointee
                if info.st_flags & datalessFlag != 0 { snapshot.unsupported = snapshot.unsupported ?? path }
                frames[frames.count - 1].shape.add(name: name, Shape.file(length: Int64(info.st_size)))
                frames[frames.count - 1].stamp.add(name: name, Shape.fileStamp(info))
                snapshot.files.append(File(
                    relativePath: relative(path, in: root), path: path, length: Int64(info.st_size),
                    allocated: Int64(info.st_blocks) * 512, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                    links: UInt16(info.st_nlink), stamp: Shape.fileStamp(info)
                ))
            case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard !frames.isEmpty else { return nil }
                snapshot.unsupported = snapshot.unsupported ?? path
                frames[frames.count - 1].shape.add(name: name, Shape.special)
                frames[frames.count - 1].stamp.add(name: name, Shape.special)
            case FTS_DNR, FTS_ERR, FTS_NS:
                return nil
            default:
                break
            }
        }
        return snapshot
    }

    private static func relative(_ path: String, in root: String) -> String {
        String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// `SF_DATALESS`: the contents live in the cloud and are not on this Mac. Reading them would download them.
let datalessFlag: UInt32 = 0x4000_0000
