import AppKit
import CleanerCore
import SwiftUI

extension Int64 {
    var formattedBytes: String { formatted(.byteCount(style: .file, spellsOutZero: false)) }
}

extension CleanableItem {
    /// Sorts items without a known date last.
    var sortDate: Date { date ?? .distantPast }
}

extension CleanupCategory {
    var label: LocalizedStringResource {
        switch self {
        case .userCaches: "Cache"
        case .logs: "Logs"
        case .developerJunk: "Developer files"
        case .trash: "In the Trash"
        case .installers: "Installer"
        case .archives: "Unpacked archive"
        case .screenshots: "Old screenshot"
        case .oldDownloads: "Not opened in months"
        case .largeFiles: "Large file"
        }
    }
}

extension FileKind {
    var label: LocalizedStringResource {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .archive: "Archive"
        case .diskImage: "Disk image"
        case .document: "Document"
        case .other: "Other"
        }
    }
}

extension ItemNote {
    var label: LocalizedStringResource {
        switch self {
        case .appIsRunning(let app): "Quit \(app) first"
        case .alreadyExtracted(let folder): "Already unpacked into “\(folder)”"
        }
    }
}

extension SafetyLevel {
    var label: LocalizedStringResource {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .caution: "Caution"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

extension BlockReason {
    var label: LocalizedStringResource {
        switch self {
        case .protectedLocation, .protectedContainer: "Protected location"
        case .personalData: "Personal folder"
        case .insideSealedPackage: "Inside an app"
        case .excludedByUser: "Excluded in Settings"
        case .doesNotExist: "Already gone"
        case .notAFileURL, .unresolvablePath, .volumeRoot, .outsideAllowedRoot: "Changed since the scan"
        }
    }
}

extension AuditLog.Entry.Action {
    var label: LocalizedStringResource {
        switch self {
        case .movedToTrash: "Moved to Trash"
        case .deleted: "Deleted"
        case .dryRun: "Test run"
        case .blocked: "Skipped"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .movedToTrash: "trash"
        case .deleted: "xmark.bin"
        case .dryRun: "testtube.2"
        case .blocked: "hand.raised"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// File and app icons for item rows, cached because lists ask for them again on every redraw.
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: CleanableItem) -> NSImage {
        let key = item.url.path(percentEncoded: false) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let workspace = NSWorkspace.shared
        let image: NSImage
        if item.category == .userCaches, let app = workspace.urlForApplication(withBundleIdentifier: item.url.lastPathComponent) {
            image = workspace.icon(forFile: app.path(percentEncoded: false))
        } else {
            image = workspace.icon(forFile: key as String)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
