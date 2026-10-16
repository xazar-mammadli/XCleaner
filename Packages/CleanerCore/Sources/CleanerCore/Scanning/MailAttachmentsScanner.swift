import Foundation

/// Finds the copies Mail saves when the user opens an attachment. The original stays in the message, so a copy can go.
/// The mailboxes themselves are never touched: `SafetyPolicy` keeps `~/Library/Mail` out of bounds.
///
/// Copies are left unselected: someone may have opened an attachment, changed it and saved it right where it was.
public struct MailAttachmentsScanner: Sendable {
    /// Where Mail keeps opened attachments: inside its container today, straight in the Library on older systems.
    public static let folders = ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Library/Mail Downloads"]

    public init() {}

    public func scan(_ context: ScanContext, progress: ScanProgressHandler? = nil) async -> ScanResult {
        var result = ScanResult()
        defer { result.report(to: progress, at: nil) }

        for relative in Self.folders {
            let folder = context.home.appending(path: relative)
            // Without Full Disk Access, merely looking into Mail's container makes macOS ask the user.
            guard context.hasFullDiskAccess || !relative.hasPrefix("Library/Containers/") else {
                result.issues.insert(.accessDenied(folder.path(percentEncoded: false)))
                continue
            }
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

            for name in names.sorted() where !name.hasPrefix(".") {
                guard !Task.isCancelled else { break }
                let url = folder.appending(path: name)
                guard !context.safety.isExcluded(url) else { continue }
                result.report(to: progress, at: url)
                let size = DirectorySizer.allocatedSize(of: url).bytes
                guard size > 0 else { continue }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                result.items.append(CleanableItem(
                    url: url, name: Self.displayName(of: url), category: .mailAttachments, size: size, safety: .review,
                    origin: .rule, root: folder, date: modified
                ))
            }
        }
        return result
    }

    /// Mail puts each attachment in a folder with a generated name; the file inside is the name the user knows.
    static func displayName(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              let first = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter({ !$0.hasPrefix(".") }).sorted().first
        else { return url.lastPathComponent }
        return first
    }
}
