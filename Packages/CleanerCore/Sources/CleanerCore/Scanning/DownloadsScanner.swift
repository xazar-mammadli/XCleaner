import Foundation

/// Finds leftovers in Downloads and on the Desktop: installers, archives that were already unpacked,
/// old screenshots and downloads nobody has opened in months. These are the user's own files,
/// so they are only offered for review and only ever go to the Trash.
public struct DownloadsScanner: Sendable {
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    public static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]

    public var screenshotMinimumAge: TimeInterval = 30 * 86_400
    public var oldDownloadMinimumAge: TimeInterval = 90 * 86_400

    public init() {}

    public func scan(_ context: ScanContext, progress: ScanProgressHandler? = nil) async -> ScanResult {
        var result = ScanResult()
        scan(context.home.appending(path: "Downloads"), offeringOldFiles: true, context, progress, into: &result)
        scan(context.home.appending(path: "Desktop"), offeringOldFiles: false, context, progress, into: &result)
        result.report(to: progress, at: nil)
        return result
    }

    private func scan(
        _ folder: URL, offeringOldFiles: Bool, _ context: ScanContext, _ progress: ScanProgressHandler?,
        into result: inout ScanResult
    ) {
        let names: [String]
        switch DirectoryListing.children(of: folder) {
        case .missing:
            return
        case .denied:
            result.issues.insert(.accessDenied(folder.path(percentEncoded: false)))
            return
        case .names(let found):
            names = found
        }
        let siblings = Set(names)

        for name in names.sorted() where !name.hasPrefix(".") {
            guard !Task.isCancelled else { return }
            let url = folder.appending(path: name)
            guard !context.safety.isExcluded(url) else { continue }
            result.report(to: progress, at: url)

            let path = url.path(percentEncoded: false)
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey,
            ])
            let isFile = values?.isDirectory != true || values?.isPackage == true
            let pathExtension = url.pathExtension.lowercased()
            let lastActivity = FileMetadata.lastUsedDate(atPath: path)
                ?? [values?.addedToDirectoryDate, values?.contentModificationDate].compactMap { $0 }.max()

            var category: CleanupCategory?
            var safety = SafetyLevel.review
            var note: ItemNote?
            if isFile, Self.installerExtensions.contains(pathExtension) {
                category = .installers
            } else if isFile, Self.archiveExtensions.contains(pathExtension),
                      let unpacked = Self.unpackedFolder(for: name, among: siblings, in: folder) {
                category = .archives
                note = .alreadyExtracted(unpacked)
            } else if isFile, FileMetadata.isScreenCapture(atPath: path), let created = values?.creationDate,
                      context.now.timeIntervalSince(created) >= screenshotMinimumAge {
                category = .screenshots
            } else if offeringOldFiles, let lastActivity, context.now.timeIntervalSince(lastActivity) >= oldDownloadMinimumAge {
                category = .oldDownloads
                safety = .caution
            }
            guard let category else { continue }

            result.items.append(CleanableItem(
                url: url, name: name, category: category, size: DirectorySizer.allocatedSize(of: url).bytes,
                safety: safety, origin: .userSelection, root: folder, date: lastActivity,
                kind: isFile ? FileMetadata.kind(ofExtension: pathExtension) : nil, note: note
            ))
        }
    }

    /// The folder an archive was unpacked into, next to it: "Report.zip" → "Report", "Logs.tar.gz" → "Logs".
    static func unpackedFolder(for archiveName: String, among siblings: Set<String>, in folder: URL) -> String? {
        var base = archiveName
        while archiveExtensions.contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        guard base != archiveName, siblings.contains(base) else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.appending(path: base).path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? base : nil
    }
}
