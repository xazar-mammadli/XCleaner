import AppKit
import CleanerCore
import Observation

/// State shared by every screen.
@Observable
final class AppModel {
    var selection: SidebarItem? = .overview
    var isShowingAccessGuide = false
    private(set) var fullDiskAccess: FullDiskAccessStatus = .unknown
    private(set) var startupDisk: VolumeUsage?

    private let accessChecker = FullDiskAccessChecker.standard(home: .homeDirectory)

    init() {
        refresh()
    }

    /// Reads again what can change behind XCleaner's back: permissions granted in System Settings, free space.
    func refresh() {
        let access = accessChecker.check()
        if access != fullDiskAccess { fullDiskAccess = access }
        let disk = try? VolumeUsage.startupDisk()
        if disk != startupDisk { startupDisk = disk }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
    }
}
