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

    let cleanup = CleanupModel()
    let largeFiles = LargeFilesModel()
    let uninstaller = UninstallerModel()
    let remainingFiles = RemainingFilesModel()
    let diskMap = DiskMapModel()
    var applicationsTool = ApplicationsTool.uninstaller
    var filesTool = FilesTool.largeFiles
    let exclusions = ExclusionStore()
    let auditLog = AuditLog(directory: AuditLog.standardDirectory)

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

    func makeServices() -> AppServices {
        let home = URL.homeDirectory
        let safety = SafetyGuard(policy: .standard(home: home, excluding: exclusions.urls))
        refresh()
        return AppServices(
            context: ScanContext(
                home: home, safety: safety, apps: WorkspaceAppCatalog(), hasFullDiskAccess: fullDiskAccess == .granted
            ),
            cleaner: Cleaner(safety: safety, auditLog: auditLog)
        )
    }

    /// Opens the Cleanup section and starts a scan, unless one is already under way or waiting for review.
    func startQuickCleanup() {
        selection = .cleanup
        if cleanup.phase == .idle || cleanup.phase == .finished {
            cleanup.scan(with: makeServices())
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
    }

    func openTrash() {
        NSWorkspace.shared.open(URL.homeDirectory.appending(path: ".Trash"))
    }
}
