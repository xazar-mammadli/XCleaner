import Foundation

/// Data left in the home Library by one app that is no longer installed.
public struct OrphanGroup: Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let items: [CleanableItem]

    public init(bundleIdentifier: String, items: [CleanableItem]) {
        self.bundleIdentifier = bundleIdentifier
        self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// A readable name: the last part of the identifier ("com.example.Photo-Editor" → "Photo-Editor").
    public var displayName: String {
        bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    }
}

/// Finds Library entries named after bundle identifiers of apps that are no longer on this Mac.
/// Every find is left for the user to review: shared frameworks also use reverse-DNS names.
public struct OrphanFinder: Sendable {
    static let locations: [LibraryLocation] = [
        .applicationSupport, .caches, .preferences, .containers, .applicationScripts, .savedState,
        .logs, .webKit, .httpStorages, .cookies,
    ]

    /// Developers whose data is never reported: macOS itself and its printing system.
    public var ignoredDevelopers: Set<String> = ["com.apple", "org.cups"]
    /// Identifiers never reported: XCleaner itself.
    public var ignoredPrefixes: [String] = ["com.xazar.xcleaner"]

    public init() {}

    /// `installedApps` tells which developers still have apps on this Mac: their leftovers may be shared and need extra care.
    public func scan(
        _ context: ScanContext, installedApps: [InstalledApp] = [], progress: ScanProgressHandler? = nil
    ) async -> (groups: [OrphanGroup], issues: Set<ScanIssue>) {
        var result = ScanResult()
        var installed: [String: Bool] = [:]
        let library = context.home.appending(path: "Library")

        for location in Self.locations {
            guard !Task.isCancelled else { break }
            let folder = library.appending(path: location.folder)
            if location.needsFullDiskAccess, !context.hasFullDiskAccess {
                if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
                    result.issues.insert(.accessDenied(folder.path(percentEncoded: false)))
                }
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

            for child in names.sorted() {
                let id = LeftoverFinder.strippingKnownSuffix(child)
                guard Self.looksLikeBundleIdentifier(id),
                      !ignoredDevelopers.contains(Self.developer(of: id)),
                      !ignoredPrefixes.contains(where: { id.lowercased().hasPrefix($0.lowercased()) }),
                      !isInstalled(id, context: context, cache: &installed)
                else { continue }
                let url = folder.appending(path: child)
                guard !context.safety.isExcluded(url) else { continue }
                result.report(to: progress, at: url)
                result.items.append(CleanableItem(
                    url: url, category: .appData, size: DirectorySizer.allocatedSize(of: url).bytes, safety: .review,
                    origin: .rule, root: folder, location: location
                ))
            }
        }
        result.report(to: progress, at: nil)

        var developers: [String: String] = [:]
        for app in installedApps where developers[Self.developer(of: app.bundleIdentifier)] == nil {
            developers[Self.developer(of: app.bundleIdentifier)] = app.name
        }

        let grouped = Dictionary(grouping: result.items) { LeftoverFinder.strippingKnownSuffix($0.url.lastPathComponent).lowercased() }
        let groups = grouped.values.compactMap { items -> OrphanGroup? in
            // Caches alone are not an app's leftovers: command-line tools keep caches too, and Cleanup handles caches.
            guard items.contains(where: { $0.location != .caches }) else { return nil }
            let id = LeftoverFinder.strippingKnownSuffix(items[0].url.lastPathComponent)
            guard let sibling = developers[Self.developer(of: id)] else { return OrphanGroup(bundleIdentifier: id, items: items) }
            let flagged = items.map { item in
                CleanableItem(
                    url: item.url, name: item.name, category: item.category, size: item.size, safety: .caution,
                    origin: item.origin, root: item.root, note: .sameDeveloperInstalled(sibling), location: item.location
                )
            }
            return OrphanGroup(bundleIdentifier: id, items: flagged)
        }
        return (groups.sorted { $0.totalBytes > $1.totalBytes }, result.issues)
    }

    /// The developer part of an identifier: `com.example` for `com.example.app`, also for group and team-prefixed forms
    /// (`group.com.example.app`, `ABCDE12345.com.example.app`).
    static func developer(of id: String) -> String {
        var parts = id.lowercased().split(separator: ".").map(String.init)
        let groupPrefixes: Set<String> = ["group", "systemgroup"]
        if let first = parts.first, groupPrefixes.contains(first) { parts.removeFirst() }
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isLetter || $0.isNumber }), parts.count > 2 {
            parts.removeFirst()
        }
        if let first = parts.first, groupPrefixes.contains(first) { parts.removeFirst() }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Reverse-DNS with at least three parts: `com.example.app`.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { part in part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// An identifier counts as installed when it, or a shorter identifier it extends, belongs to an app on this Mac:
    /// `com.example.app.helper` is covered by `com.example.app`.
    private func isInstalled(_ id: String, context: ScanContext, cache: inout [String: Bool]) -> Bool {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            let candidate = parts.joined(separator: ".")
            let known: Bool
            if let cached = cache[candidate] {
                known = cached
            } else {
                known = context.apps.applicationName(forBundleIdentifier: candidate) != nil
                cache[candidate] = known
            }
            if known { return true }
            parts.removeLast()
        }
        return false
    }
}
