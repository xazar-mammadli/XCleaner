import Foundation

/// Lists what sits in the Trash on this Mac and on connected drives.
public struct TrashScanner: Sendable {
    /// Trash folders on other disks.
    public var externalTrashes: @Sendable () -> [URL]

    public init(externalTrashes: @escaping @Sendable () -> [URL] = TrashScanner.mountedVolumeTrashes) {
        self.externalTrashes = externalTrashes
    }

    public func scan(_ context: ScanContext, progress: ScanProgressHandler? = nil) async -> ScanResult {
        var result = ScanResult()
        defer { result.report(to: progress, at: nil) }
        let folders = [context.home.appending(path: ".Trash")] + externalTrashes()

        for folder in folders {
            guard !Task.isCancelled else { break }
            let names: [String]
            switch DirectoryListing.children(of: folder) {
            case .missing:
                continue
            case .denied:
                result.issues.insert(.accessDenied(folder.path(percentEncoded: false)))
                continue
            case .names(let found):
                names = found
            }

            for name in names.sorted() where name != ".DS_Store" {
                guard !Task.isCancelled else { break }
                let url = folder.appending(path: name)
                guard !context.safety.isExcluded(url) else { continue }
                result.report(to: progress, at: url)
                let size = DirectorySizer.allocatedSize(of: url).bytes
                result.items.append(CleanableItem(
                    url: url, name: name, category: .trash, size: size, safety: .review, origin: .rule, root: folder
                ))
            }
        }
        return result
    }

    /// The current user's Trash folder on every mounted, writable, local disk other than the startup disk.
    public static func mountedVolumeTrashes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsRootFileSystem != true, values.volumeIsReadOnly != true
            else { return nil }
            return volume.appending(path: ".Trashes/\(getuid())")
        }
    }
}
