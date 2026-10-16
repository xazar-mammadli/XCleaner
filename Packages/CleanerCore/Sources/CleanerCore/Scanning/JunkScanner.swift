import Foundation

/// Finds caches, logs and developer junk: files apps recreate on their own when they need them.
public struct JunkScanner: Sendable {
    public let rules: [CleanupRule]

    public init(rules: [CleanupRule] = CleanupRule.standard) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext, progress: ScanProgressHandler? = nil) async -> ScanResult {
        var result = ScanResult()
        defer { result.report(to: progress, at: nil) }
        let running = RunningApps(context.apps.runningApplications())

        for rule in rules {
            guard !Task.isCancelled else { break }
            let folder = context.home.appending(path: rule.folder)
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

            for name in names.sorted() where rule.offers(name) {
                guard !Task.isCancelled else { break }
                let url = folder.appending(path: name)
                guard !context.safety.isExcluded(url) else { continue }
                if !context.hasFullDiskAccess, rule.needsFullDiskAccess.contains(name.lowercased()) {
                    result.issues.insert(.accessDenied(url.path(percentEncoded: false)))
                    continue
                }
                result.report(to: progress, at: url)
                let size = DirectorySizer.allocatedSize(of: url).bytes
                guard size > 0 else { continue }
                result.items.append(item(for: rule, named: name, at: url, in: folder, size: size, context: context, running: running))
            }
        }
        return result
    }

    private func item(
        for rule: CleanupRule, named name: String, at url: URL, in folder: URL,
        size: Int64, context: ScanContext, running: RunningApps
    ) -> CleanableItem {
        var displayName = rule.displayName ?? name
        var safety = rule.safety
        var owner = rule.owner.flatMap { running.name(forBundleID: $0) }

        if rule.childrenAreBundleIDs {
            if let appleSafety = rule.appleSafety, name.lowercased().hasPrefix("com.apple.") { safety = appleSafety }
            if let appName = running.name(forBundleID: name) ?? context.apps.applicationName(forBundleIdentifier: name) {
                displayName = appName
            }
            owner = owner ?? running.name(forBundleID: name) ?? running.name(matchingFolder: name)
        }
        return CleanableItem(
            url: url, name: displayName, category: rule.category, size: size, safety: safety,
            origin: .rule, root: folder, note: owner.map(ItemNote.appIsRunning)
        )
    }
}

/// The apps running when a scan started, looked up by bundle identifier or by name.
private struct RunningApps {
    let byBundleID: [String: String]
    let byLowercasedName: [String: String]

    init(_ apps: [String: String]) {
        byBundleID = apps
        byLowercasedName = Dictionary(apps.values.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func name(forBundleID bundleID: String) -> String? {
        byBundleID[bundleID]
    }

    /// Cache folders named after an app rather than its bundle identifier: "Firefox", or "Google" for Google Chrome.
    func name(matchingFolder folder: String) -> String? {
        guard !folder.contains(".") else { return nil }
        let key = folder.lowercased()
        return byLowercasedName[key] ?? byLowercasedName.first { $0.key.hasPrefix(key + " ") }?.value
    }
}
