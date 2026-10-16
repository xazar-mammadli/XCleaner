import CoreGraphics
import Foundation

/// One folder or file in the disk map. Small entries are folded into their parent's `otherBytes`,
/// so the tree stays small enough to keep in memory for a whole home folder.
public struct DiskNode: Identifiable, Sendable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    /// Biggest first.
    public let children: [DiskNode]
    /// Space taken by files and folders too small to list one by one.
    public let otherBytes: Int64

    public init(url: URL, name: String, size: Int64, isDirectory: Bool, children: [DiskNode] = [], otherBytes: Int64 = 0) {
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
        self.otherBytes = otherBytes
    }

    /// The tree without the entry at `url`, with every folder above it made smaller by its size.
    public func removing(_ url: URL) -> DiskNode {
        guard let index = children.firstIndex(where: { $0.url == url }) else {
            guard let path = children.firstIndex(where: { url.path(percentEncoded: false).hasPrefix($0.url.path(percentEncoded: false) + "/") })
            else { return self }
            var updated = children
            let before = updated[path].size
            updated[path] = updated[path].removing(url)
            return DiskNode(
                url: self.url, name: name, size: size - (before - updated[path].size), isDirectory: isDirectory,
                children: updated.sorted { $0.size > $1.size }, otherBytes: otherBytes
            )
        }
        var updated = children
        let removed = updated.remove(at: index)
        return DiskNode(
            url: self.url, name: name, size: size - removed.size, isDirectory: isDirectory, children: updated, otherBytes: otherBytes
        )
    }

    /// The node at `url`, searching down from here.
    public func node(at url: URL) -> DiskNode? {
        if self.url == url { return self }
        let path = url.path(percentEncoded: false)
        guard let next = children.first(where: { $0.url == url || path.hasPrefix($0.url.path(percentEncoded: false) + "/") })
        else { return nil }
        return next.node(at: url)
    }
}

/// Measures a folder tree in one pass for the disk map.
public struct DiskMapScanner: Sendable {
    /// Entries smaller than this are folded into "Other".
    public var minimumNodeSize: Int64

    public init(minimumNodeSize: Int64 = 1_000_000) {
        self.minimumNodeSize = minimumNodeSize
    }

    /// `progress` receives the number of files seen so far, every few thousand files.
    public func scan(_ root: URL, progress: (@Sendable (Int) -> Void)? = nil) async -> DiskNode? {
        let rootPath = PathUtilities.realPath(root.path(percentEncoded: false)) ?? root.path(percentEncoded: false)
        guard let cPath = strdup(rootPath) else { return nil }
        defer { free(cPath) }
        let roots: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }

        var stack: [Builder] = []
        var result: DiskNode?
        var filesSeen = 0
        var seenHardLinks = Set<HardLink>()

        while let entry = fts_read(stream), !Task.isCancelled {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                let builder = Builder(path: path, isPackage: stack.last?.isPackage == true || Self.isPackage(path))
                if entry.pointee.fts_statp.pointee.st_flags & Self.dataless != 0 {
                    fts_set(stream, entry, FTS_SKIP)
                }
                stack.append(builder)
            case FTS_DP, FTS_DNR:
                // An unreadable folder comes back as FTS_DNR instead of FTS_DP, after its FTS_D.
                guard let finished = stack.popLast() else { break }
                let node = finished.node()
                if let parent = stack.last {
                    parent.size += node.size
                    if node.size >= minimumNodeSize, !parent.isPackage {
                        parent.children.append(node)
                    } else {
                        parent.otherBytes += node.size
                    }
                } else {
                    result = node
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                filesSeen += 1
                if filesSeen % 5_000 == 0 { progress?(filesSeen) }
                let stat = entry.pointee.fts_statp.pointee
                if stat.st_nlink > 1, (stat.st_mode & S_IFMT) == S_IFREG,
                   !seenHardLinks.insert(HardLink(device: stat.st_dev, inode: stat.st_ino)).inserted {
                    continue
                }
                let bytes = Int64(stat.st_blocks) * 512
                guard let parent = stack.last else {
                    // The root itself is a file.
                    let path = String(cString: entry.pointee.fts_path)
                    result = DiskNode(url: URL(filePath: path), name: (path as NSString).lastPathComponent, size: bytes, isDirectory: false)
                    continue
                }
                parent.size += bytes
                if bytes >= minimumNodeSize, !parent.isPackage {
                    let path = String(cString: entry.pointee.fts_path)
                    parent.children.append(DiskNode(url: URL(filePath: path), name: (path as NSString).lastPathComponent, size: bytes, isDirectory: false))
                } else {
                    parent.otherBytes += bytes
                }
            default:
                break
            }
        }
        progress?(filesSeen)
        return Task.isCancelled ? nil : result
    }

    static let packageExtensions: Set<String> = LargeFileScanner.packageExtensions

    static func isPackage(_ path: String) -> Bool {
        packageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static let dataless: UInt32 = 0x4000_0000

    private struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private final class Builder {
        let path: String
        let isPackage: Bool
        var size: Int64 = 0
        var otherBytes: Int64 = 0
        var children: [DiskNode] = []

        init(path: String, isPackage: Bool) {
            self.path = path
            self.isPackage = isPackage
        }

        func node() -> DiskNode {
            DiskNode(
                url: URL(filePath: path), name: (path as NSString).lastPathComponent, size: size, isDirectory: true,
                children: children.sorted { $0.size > $1.size }, otherBytes: otherBytes
            )
        }
    }
}

/// Squarified treemap layout: rectangles with areas proportional to the values, kept as close to square as possible.
public enum Treemap {
    /// `values` should be sorted biggest first. Zero or negative values get an empty rectangle.
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var frames = [CGRect](repeating: .zero, count: values.count)
        let positive = values.indices.filter { values[$0] > 0 }
        let total = positive.reduce(0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return frames }

        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var start = 0
        while start < positive.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [positive[start]]
            var worst = worstRatio(row.map { values[$0] * scale }, side: side)
            var next = start + 1
            while next < positive.count {
                let candidate = row + [positive[next]]
                let candidateWorst = worstRatio(candidate.map { values[$0] * scale }, side: side)
                if candidateWorst > worst { break }
                row = candidate
                worst = candidateWorst
                next += 1
            }

            let rowArea = row.reduce(0) { $0 + values[$1] * scale }
            if remaining.width >= remaining.height {
                let width = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for index in row {
                    let height = CGFloat(values[index] * scale) / width
                    frames[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for index in row {
                    let width = CGFloat(values[index] * scale) / height
                    frames[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            start = next
        }
        return frames
    }

    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard let largest = areas.max(), let smallest = areas.min(), smallest > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
