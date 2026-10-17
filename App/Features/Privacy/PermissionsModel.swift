import AppKit
import CleanerCore
import SwiftUI

/// Drives App Permissions: which apps may use what, read from macOS's privacy databases, and resetting an answer.
@Observable
final class PermissionsModel {
    struct Entry: Identifiable {
        var id: String { grant.id }
        let grant: PermissionGrant
        let name: String
        /// The app, when it is installed.
        let appURL: URL?
        /// For Automation: the name of the app it may control.
        let targetName: String?

        var bundleIdentifier: String? {
            if case .app(let identifier) = grant.client { return identifier }
            return nil
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var failure: PermissionReader.Failure?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// The app whose answer macOS kept after a reset.
    private(set) var keptAfterReset: Entry?
    var showsRefused = false
    var searchText = ""

    /// The permissions with the apps that answered, in the order System Settings lists them.
    var sections: [(permission: PrivacyPermission, entries: [Entry])] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let visible = entries.filter { entry in
            (showsRefused || entry.grant.decision != .denied)
                && (query.isEmpty || entry.name.localizedStandardContains(query) || entry.targetName?.localizedStandardContains(query) == true)
        }
        let byPermission = Dictionary(grouping: visible, by: \.grant.permission)
        return PrivacyPermission.allCases.compactMap { permission in
            byPermission[permission].map { (permission, $0) }
        }
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        let home = URL.homeDirectory
        Task {
            let result = await Task.detached(priority: .userInitiated) { PermissionReader.standard(home: home).read() }.value
            switch result {
            case .success(let grants):
                entries = grants.map { Self.entry(for: $0) }.sorted { first, second in
                    let order = first.name.localizedStandardCompare(second.name)
                    return order == .orderedSame ? first.id < second.id : order == .orderedAscending
                }
                failure = nil
            case .failure(let failure):
                entries = []
                self.failure = failure
            }
            hasLoaded = true
            isLoading = false
        }
    }

    /// Makes macOS forget the answer, then reads the permissions again to see whether it did.
    func reset(_ entry: Entry) async {
        guard let identifier = entry.bundleIdentifier else { return }
        keptAfterReset = nil
        let permission = entry.grant.permission
        _ = await Task.detached { PermissionReset.reset(permission, for: identifier) }.value
        let home = URL.homeDirectory
        let result = await Task.detached { PermissionReader.standard(home: home).read() }.value
        if case .success(let grants) = result {
            entries = grants.map { Self.entry(for: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if grants.contains(where: { $0.id == entry.id }) { keptAfterReset = entry }
        }
    }

    private static func entry(for grant: PermissionGrant) -> Entry {
        switch grant.client {
        case .app(let identifier):
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            return Entry(grant: grant, name: url.map(appName) ?? identifier, appURL: url, targetName: targetName(grant.target))
        case .tool(let path):
            return Entry(grant: grant, name: (path as NSString).lastPathComponent, appURL: nil, targetName: targetName(grant.target))
        }
    }

    private static func targetName(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map(appName) ?? identifier
    }

    private static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

extension PrivacyPermission {
    var title: LocalizedStringResource {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .systemAudioRecording: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .fullDiskAccess: "Full Disk Access"
        case .desktopFolder: "Desktop Folder"
        case .documentsFolder: "Documents Folder"
        case .downloadsFolder: "Downloads Folder"
        case .networkVolumes: "Network Volumes"
        case .removableVolumes: "Removable Volumes"
        case .otherAppsData: "Other Apps' Data"
        case .appManagement: "App Management"
        case .automation: "Automation"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .photos: "Photos"
        case .mediaLibrary: "Media & Apple Music"
        case .speechRecognition: "Speech Recognition"
        case .bluetooth: "Bluetooth"
        case .focus: "Focus"
        case .developerTools: "Developer Tools"
        case .passkeys: "Passkeys for Web Browsers"
        }
    }

    /// What the permission lets an app do, for the reset dialog.
    var effect: LocalizedStringResource {
        switch self {
        case .camera: "use the camera"
        case .microphone: "use the microphone"
        case .screenRecording: "record the screen"
        case .systemAudioRecording: "record the sound your Mac plays"
        case .accessibility: "control your Mac"
        case .inputMonitoring: "see what you type"
        case .fullDiskAccess: "read all your files"
        case .desktopFolder: "open files on the Desktop"
        case .documentsFolder: "open files in Documents"
        case .downloadsFolder: "open files in Downloads"
        case .networkVolumes: "open files on network volumes"
        case .removableVolumes: "open files on removable volumes"
        case .otherAppsData: "read other apps' data"
        case .appManagement: "change other apps"
        case .automation: "control another app"
        case .contacts: "read your contacts"
        case .calendars: "use your calendars"
        case .reminders: "use your reminders"
        case .photos: "use your photos"
        case .mediaLibrary: "use your music and media"
        case .speechRecognition: "recognize speech"
        case .bluetooth: "use Bluetooth"
        case .focus: "see your Focus status"
        case .developerTools: "run software that isn't checked by macOS"
        case .passkeys: "use your passkeys on websites"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .systemAudioRecording: "waveform"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        case .fullDiskAccess: "externaldrive"
        case .desktopFolder: "menubar.dock.rectangle"
        case .documentsFolder: "doc"
        case .downloadsFolder: "arrow.down.circle"
        case .networkVolumes: "network"
        case .removableVolumes: "externaldrive.badge.plus"
        case .otherAppsData: "square.on.square"
        case .appManagement: "app.badge"
        case .automation: "gearshape.2"
        case .contacts: "person.crop.circle"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .photos: "photo"
        case .mediaLibrary: "music.note"
        case .speechRecognition: "waveform.and.mic"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .focus: "moon"
        case .developerTools: "hammer"
        case .passkeys: "person.badge.key"
        }
    }
}
