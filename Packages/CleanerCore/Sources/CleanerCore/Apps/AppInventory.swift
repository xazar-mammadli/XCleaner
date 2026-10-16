import Foundation
import Security

/// An app the user installed and could remove.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
    public let version: String?

    public init(url: URL, bundleIdentifier: String, name: String, version: String?) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
    }

    /// The bundle itself as a removable item. The user picks it, so it only ever goes to the Trash.
    public func asItem(size: Int64) -> CleanableItem {
        CleanableItem(
            url: url, name: name, category: .application, size: size, safety: .safe,
            origin: .userSelection, root: url.deletingLastPathComponent()
        )
    }
}

/// Lists the apps in the Applications folders, one level of subfolders included
/// (so `/Applications/Some Suite/Some App.app` is found too).
public struct AppInventory: Sendable {
    public let folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    public static func standard(home: URL) -> AppInventory {
        AppInventory(folders: [URL(filePath: "/Applications"), home.appending(path: "Applications")])
    }

    /// Every app that can be removed. Apps protected by System Integrity Protection, such as Safari, and the given
    /// bundle identifiers (XCleaner itself) are left out.
    public func apps(excluding excludedIDs: Set<String> = []) -> [InstalledApp] {
        var found: [InstalledApp] = []
        var seen = Set<String>()
        for folder in folders {
            for url in Self.appBundles(in: folder, depth: 2) {
                let path = url.path(percentEncoded: false)
                guard seen.insert(path).inserted, !Self.isSystemProtected(path),
                      let app = Self.read(url), !excludedIDs.contains(app.bundleIdentifier)
                else { continue }
                found.append(app)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func appBundles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        else { return [] }
        var bundles: [URL] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            if name.lowercased().hasSuffix(".app") {
                bundles.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map({ $0.isDirectory == true && $0.isPackage != true }) == true {
                bundles += appBundles(in: url, depth: depth - 1)
            }
        }
        return bundles
    }

    static func read(_ url: URL) -> InstalledApp? {
        guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty
        else { return nil }
        let displayName = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        let name = displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        return InstalledApp(
            url: url, bundleIdentifier: bundleIdentifier, name: name, version: info["CFBundleShortVersionString"] as? String
        )
    }

    /// `SF_RESTRICTED`: macOS protects the bundle, so nothing could remove it anyway.
    static func isSystemProtected(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & 0x0008_0000 != 0
    }
}

enum CodeSignature {
    /// The app groups an app is entitled to; their containers hold data the app shares with its helpers.
    static func appGroups(of url: URL) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return [] }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let signing = information as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
