import Foundation

/// How a disk's space is split, in the same terms Finder uses.
public struct VolumeUsage: Sendable, Equatable {
    public let name: String
    public let totalBytes: Int64
    /// Free right now.
    public let freeBytes: Int64
    /// Space macOS frees on its own when it needs room: local snapshots, optimized iCloud copies and the like.
    public let purgeableBytes: Int64

    public init(name: String, totalBytes: Int64, freeBytes: Int64, purgeableBytes: Int64) {
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.purgeableBytes = purgeableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes - purgeableBytes) }
    /// What Finder calls "available": free plus purgeable.
    public var availableBytes: Int64 { freeBytes + purgeableBytes }

    /// The disk holding `url`.
    public static func current(for url: URL) throws -> VolumeUsage {
        let values = try url.resourceValues(forKeys: [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeUsage(
            name: values.volumeLocalizedName ?? "",
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: free,
            purgeableBytes: max(0, available - free)
        )
    }

    /// The startup disk, named as Finder shows it ("Macintosh HD"). Space is measured on the volume
    /// holding the home folder, because the sealed system volume itself never changes.
    public static func startupDisk() throws -> VolumeUsage {
        let data = try current(for: .homeDirectory)
        let name = try? URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        return VolumeUsage(
            name: name ?? data.name,
            totalBytes: data.totalBytes,
            freeBytes: data.freeBytes,
            purgeableBytes: data.purgeableBytes
        )
    }
}
