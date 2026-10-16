import AppKit
import CleanerCore

/// Everything a scan or a cleanup needs, built fresh for each run so the latest exclusions apply.
nonisolated struct AppServices: Sendable {
    let context: ScanContext
    let cleaner: Cleaner
}

/// Tells the engine which apps are installed and running.
nonisolated struct WorkspaceAppCatalog: AppCatalog {
    func runningApplications() -> [String: String] {
        var apps: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier else { continue }
            apps[bundleIdentifier] = app.localizedName ?? bundleIdentifier
        }
        return apps
    }

    func applicationName(forBundleIdentifier bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// The folders the user asked XCleaner to leave alone.
@Observable
final class ExclusionStore {
    private(set) var paths: [String]

    init() {
        paths = UserDefaults.standard.stringArray(forKey: PreferenceKey.excludedPaths) ?? []
    }

    var urls: [URL] { paths.map { URL(filePath: $0) } }

    func add(_ urls: [URL]) {
        for url in urls {
            let path = (url.path(percentEncoded: false) as NSString).standardizingPath
            if !paths.contains(path) { paths.append(path) }
        }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        save()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        save()
    }

    private func save() {
        UserDefaults.standard.set(paths, forKey: PreferenceKey.excludedPaths)
    }
}
