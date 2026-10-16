import AppKit
import CleanerCore
import SwiftUI

/// Drives Startup Items: what starts on its own, whether it may, and switching launch agents off and on.
@Observable
final class StartupItemsModel {
    private(set) var snapshot: StartupSnapshot?
    /// The app each job belongs to, by the job's file.
    private(set) var owners: [URL: URL] = [:]
    /// What to call each job, by the job's file: its app's name when known, otherwise its label.
    private(set) var names: [URL: String] = [:]
    private(set) var isLoading = false
    /// Jobs being switched right now.
    private(set) var switching: Set<URL> = []
    /// A job that launchctl refused to switch.
    private(set) var failedSwitch: String?
    private(set) var lastReport: CleaningReport?

    var loginItems: [LoginItem] { snapshot?.loginItems ?? [] }
    var agents: [LaunchItem] { jobs(of: .agent) }
    var daemons: [LaunchItem] { jobs(of: .daemon) }
    /// Jobs that can't run: leftovers of deleted apps, and empty files.
    var removable: [LaunchItem] { (agents + daemons).filter(canRemove) }

    /// Jobs from the folders. The ones apps registered themselves, and login items, are switched in System Settings.
    func canSwitch(_ item: LaunchItem) -> Bool {
        item.bundledIn == nil && item.problem == nil
    }

    func canRemove(_ item: LaunchItem) -> Bool {
        item.bundledIn == nil && item.problem != nil
    }

    /// Daemons run for the whole Mac, and the files outside the user's own folder belong to the system:
    /// changing either asks for the administrator's password.
    func needsAdministrator(toSwitch item: LaunchItem) -> Bool {
        item.kind == .daemon
    }

    func name(of item: LaunchItem) -> String {
        names[item.plistURL] ?? item.label
    }

    private func jobs(of kind: LaunchItem.Kind) -> [LaunchItem] {
        (snapshot?.jobs ?? []).filter { $0.kind == kind }.sorted { first, second in
            let order = name(of: first).localizedStandardCompare(name(of: second))
            return order == .orderedSame ? first.label < second.label : order == .orderedAscending
        }
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        Task { await reload() }
    }

    func setOn(_ isOn: Bool, _ item: LaunchItem) {
        switching.insert(item.id)
        failedSwitch = nil
        Task {
            if needsAdministrator(toSwitch: item) {
                let request = PrivilegedRequest.setDaemon(label: item.label, enabled: isOn, plist: item.plistURL.path(percentEncoded: false))
                switch Administrator.perform(request) {
                case .success(let response) where response.succeeded: break
                case .failure(.cancelled): break
                default: failedSwitch = item.label
                }
            } else {
                let worked = await Task.detached { LaunchControl.setEnabled(isOn, label: item.label, plist: item.plistURL) }.value
                if !worked { failedSwitch = item.label }
            }
            await reload()
            switching.remove(item.id)
        }
    }

    func remove(_ items: [LaunchItem], with services: AppServices, method: DeletionMethod) async {
        let cleanable = items.map { item in
            CleanableItem(
                url: item.plistURL, name: item.label, category: .appData,
                size: Int64((try? item.plistURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                safety: .review, origin: .userSelection, root: item.plistURL.deletingLastPathComponent(), location: .launchAgents
            )
        }
        lastReport = await Administrator.clean(cleanable, with: services.cleaner, method: method)
        await reload()
    }

    private func reload() async {
        isLoading = true
        let home = URL.homeDirectory
        let (snapshot, owners) = await Task.detached(priority: .userInitiated) {
            let apps = AppInventory.standard(home: home).apps()
            let snapshot = StartupSnapshot.read(home: home, apps: apps)
            let owners = snapshot.jobs.compactMap { job in owner(of: job, among: apps).map { (job.plistURL, $0) } }
            return (snapshot, Dictionary(owners, uniquingKeysWith: { first, _ in first }))
        }.value
        self.snapshot = snapshot
        self.owners = owners
        names = owners.mapValues { url in
            let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        isLoading = false
    }
}

/// The app a job belongs to: the one it comes inside, one it names, or the one its program sits in.
/// Failing those, the one app whose identifier starts like the job's label (`com.docker.vmnetd` → Docker).
nonisolated private func owner(of job: LaunchItem, among apps: [InstalledApp]) -> URL? {
    if let bundle = job.bundledIn { return bundle }
    for identifier in job.bundleIdentifiers {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
    }
    if let program = job.program, let range = program.range(of: ".app/") {
        return URL(filePath: String(program[..<range.lowerBound]) + ".app")
    }
    // A broken job is better shown by its own name than tied to an app it may not belong to anymore.
    let parts = job.label.split(separator: ".")
    guard job.problem == nil, parts.count >= 3 else { return nil }
    let developer = parts.prefix(2).joined(separator: ".") + "."
    let matches = apps.filter { $0.bundleIdentifier.hasPrefix(developer) }
    return matches.count == 1 ? matches[0].url : nil
}
