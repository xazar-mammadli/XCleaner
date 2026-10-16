import Foundation

/// Finds the files an app keeps in the home Library. Folders named after its bundle identifier are certainly its own
/// and start selected; folders that only share its name, and group containers its sibling apps may also use,
/// are left for the user to review.
public struct LeftoverFinder: Sendable {
    public init() {}

    public func leftovers(of app: InstalledApp, context: ScanContext) -> ScanResult {
        leftovers(bundleIdentifier: app.bundleIdentifier, name: app.name, appGroups: CodeSignature.appGroups(of: app.url), context: context)
    }

    public func leftovers(bundleIdentifier id: String, name: String?, appGroups: [String], context: ScanContext) -> ScanResult {
        var result = ScanResult()
        let library = context.home.appending(path: "Library")
        // Generic names ("Data", "App") would match other apps' folders.
        let matchableName = name.flatMap { $0.count >= 4 ? $0.lowercased() : nil }
        let groups = Set(appGroups)

        // Per-machine preferences live one level down, in Preferences/ByHost.
        let folders = LibraryLocation.allCases.map { ($0, library.appending(path: $0.folder)) }
            + [(.preferences, library.appending(path: "Preferences/ByHost"))]

        for (location, folder) in folders {
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

            for child in names.sorted() where !child.hasPrefix(".") {
                let safety: SafetyLevel
                if location == .groupContainers {
                    guard groups.contains(child) else { continue }
                    safety = .review
                } else if Self.belongs(child, to: id, in: location) {
                    // `com.example.app.pro` may be a different app that is also installed; its files are not ours.
                    let base = Self.strippingKnownSuffix(child)
                    if base.caseInsensitiveCompare(id) != .orderedSame,
                       context.apps.applicationName(forBundleIdentifier: base) != nil {
                        continue
                    }
                    safety = location == .launchAgents ? .review : .safe
                } else if let matchableName, Self.namedLocations.contains(location), child.lowercased() == matchableName {
                    safety = .review
                } else {
                    continue
                }
                let url = folder.appending(path: child)
                guard !context.safety.isExcluded(url) else { continue }
                result.items.append(CleanableItem(
                    url: url, category: .appData, size: DirectorySizer.allocatedSize(of: url).bytes, safety: safety,
                    origin: .rule, root: folder, location: location
                ))
            }
        }
        return result
    }

    /// Locations where apps also use their plain name for folders.
    static let namedLocations: Set<LibraryLocation> = [.applicationSupport, .caches, .logs]

    /// Whether a Library entry is named after the bundle identifier: the identifier itself, the identifier with a
    /// dot-suffix (`com.example.app.helper`, `com.example.app.plist`), never just a longer word (`com.example.application`).
    static func belongs(_ name: String, to id: String, in location: LibraryLocation) -> Bool {
        let base = strippingKnownSuffix(name)
        return base.caseInsensitiveCompare(id) == .orderedSame || base.lowercased().hasPrefix(id.lowercased() + ".")
    }

    /// `com.example.app.plist` → `com.example.app`, likewise for saved states and cookie files.
    static func strippingKnownSuffix(_ name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
