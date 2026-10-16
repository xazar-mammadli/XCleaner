import Foundation

/// An add-on that plugs into macOS: a preference pane, a Quick Look or Spotlight plug-in, a screen saver, an audio
/// plug-in or a service. Each is one bundle in a known folder, so removing it is removing that bundle.
public struct ExtensionItem: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case preferencePane, quickLook, spotlight, screenSaver, internetPlugIn, audioPlugIn, service
    }

    public var id: URL { url }
    public let url: URL
    public let name: String
    public let kind: Kind
    public let version: String?
    /// Installed for everyone on the Mac, in `/Library`, so removing it needs the administrator's password.
    public let isSystemWide: Bool
    public let size: Int64

    /// The folder it was found in, which removal stays inside.
    public var folder: URL { url.deletingLastPathComponent() }
}

/// Lists the add-ons in the user's Library and in `/Library`.
public struct ExtensionScanner: Sendable {
    /// Where each kind lives, relative to a Library folder, and the bundle extensions it uses there.
    public static let locations: [(folder: String, kind: ExtensionItem.Kind, extensions: Set<String>)] = [
        ("PreferencePanes", .preferencePane, ["prefpane"]),
        ("QuickLook", .quickLook, ["qlgenerator"]),
        ("Spotlight", .spotlight, ["mdimporter"]),
        ("Screen Savers", .screenSaver, ["saver", "qtz"]),
        ("Internet Plug-Ins", .internetPlugIn, ["plugin", "webplugin"]),
        ("Audio/Plug-Ins/Components", .audioPlugIn, ["component"]),
        ("Audio/Plug-Ins/VST", .audioPlugIn, ["vst"]),
        ("Audio/Plug-Ins/VST3", .audioPlugIn, ["vst3"]),
        ("Audio/Plug-Ins/HAL", .audioPlugIn, ["driver", "plugin"]),
        ("Services", .service, ["workflow", "service"]),
    ]

    /// The system-wide folders, which a privileged run may remove add-ons from.
    public static var systemFolders: [String] { locations.map { "/Library/" + $0.folder } }

    public let home: URL
    public let systemLibrary: URL

    public init(home: URL, systemLibrary: URL = URL(filePath: "/Library")) {
        self.home = home
        self.systemLibrary = systemLibrary
    }

    public func extensions() -> [ExtensionItem] {
        let libraries = [(home.appending(path: "Library"), false), (systemLibrary, true)]
        return libraries.flatMap { library, isSystemWide in
            Self.locations.flatMap { location in
                let folder = library.appending(path: location.folder)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
                return names.sorted().compactMap { name -> ExtensionItem? in
                    guard location.extensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
                    let url = folder.appending(path: name)
                    let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
                    let bundleName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                    return ExtensionItem(
                        url: url,
                        name: bundleName.flatMap { $0.isEmpty ? nil : $0 } ?? (name as NSString).deletingPathExtension,
                        kind: location.kind,
                        version: info["CFBundleShortVersionString"] as? String,
                        isSystemWide: isSystemWide,
                        size: DirectorySizer.allocatedSize(of: url).bytes
                    )
                }
            }
        }
    }
}

/// An extension installed in a web browser. XCleaner only lists them: browsers keep their own records of what is
/// installed and put back what is deleted behind their back, so removal belongs in the browser itself.
public struct BrowserExtension: Sendable, Identifiable, Hashable {
    public var id: String { "\(browser.bundleIdentifier)/\(profile)/\(identifier)" }
    public let browser: Browser
    /// The profile's own name, such as "Person 1", or the app that brings it, for Safari.
    public let profile: String
    public let identifier: String
    public let name: String
    public let version: String?
    /// An icon from the extension's own files, when it has one.
    public let icon: URL?
}

public struct Browser: Sendable, Hashable {
    public let name: String
    public let bundleIdentifier: String

    public static let chrome = Browser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
    public static let edge = Browser(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac")
    public static let brave = Browser(name: "Brave", bundleIdentifier: "com.brave.Browser")
    public static let vivaldi = Browser(name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi")
    public static let opera = Browser(name: "Opera", bundleIdentifier: "com.operasoftware.Opera")
    public static let arc = Browser(name: "Arc", bundleIdentifier: "company.thebrowser.Browser")
    public static let chromium = Browser(name: "Chromium", bundleIdentifier: "org.chromium.Chromium")
    public static let firefox = Browser(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
    public static let safari = Browser(name: "Safari", bundleIdentifier: "com.apple.Safari")
}

public struct BrowserExtensionScanner: Sendable {
    /// Browsers built on Chromium keep the same layout: profiles with an `Extensions` folder each.
    static let chromium: [(browser: Browser, folder: String)] = [
        (.chrome, "Library/Application Support/Google/Chrome"),
        (.edge, "Library/Application Support/Microsoft Edge"),
        (.brave, "Library/Application Support/BraveSoftware/Brave-Browser"),
        (.vivaldi, "Library/Application Support/Vivaldi"),
        (.opera, "Library/Application Support/com.operasoftware.Opera"),
        (.arc, "Library/Application Support/Arc/User Data"),
        (.chromium, "Library/Application Support/Chromium"),
    ]

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public func extensions() -> [BrowserExtension] {
        Self.chromium.flatMap { chromiumExtensions(of: $0.browser, in: home.appending(path: $0.folder)) }
            + firefoxExtensions(in: home.appending(path: "Library/Application Support/Firefox/Profiles"))
            + safariExtensions()
    }

    func chromiumExtensions(of browser: Browser, in root: URL) -> [BrowserExtension] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        // Profiles are "Default" and "Profile 1", "Profile 2"…; Opera keeps its one profile in the root itself.
        var profiles = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted().map { (root.appending(path: $0), $0) }
        if profiles.isEmpty, FileManager.default.fileExists(atPath: root.appending(path: "Extensions").path(percentEncoded: false)) {
            profiles = [(root, "Default")]
        }
        let displayNames = Self.chromiumProfileNames(in: root)
        return profiles.flatMap { folder, profile in
            let extensions = folder.appending(path: "Extensions")
            let identifiers = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path(percentEncoded: false))) ?? []
            return identifiers.filter { !$0.hasPrefix(".") && $0 != "Temp" }.sorted().compactMap { identifier in
                Self.readChromiumExtension(extensions.appending(path: identifier)).map { manifest in
                    BrowserExtension(
                        browser: browser, profile: displayNames[profile] ?? profile, identifier: identifier,
                        name: manifest.name, version: manifest.version, icon: manifest.icon
                    )
                }
            }
        }
    }

    /// "Default" → "Person 1", as the browser's profile menu shows it (`Local State`).
    static func chromiumProfileNames(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    /// The newest version folder's manifest, with a name from the extension's own translations when it uses one.
    static func readChromiumExtension(_ folder: URL) -> (name: String, version: String?, icon: URL?)? {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending } ?? []
        guard let latest = versions.last else { return nil }
        let directory = folder.appending(path: latest)
        guard let data = try? Data(contentsOf: directory.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var name = manifest["name"] as? String
        else { return nil }
        if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            let key = String(name.dropFirst(6).dropLast(2)).lowercased()
            let locale = manifest["default_locale"] as? String ?? "en"
            if let messagesData = try? Data(contentsOf: directory.appending(path: "_locales/\(locale)/messages.json")),
               let messages = try? JSONSerialization.jsonObject(with: messagesData) as? [String: Any],
               let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String {
                name = message
            }
        }
        let icons = manifest["icons"] as? [String: String] ?? [:]
        let icon = icons.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { directory.appending(path: $0.value) }
        return (name, manifest["version"] as? String, icon)
    }

    func firefoxExtensions(in profiles: URL) -> [BrowserExtension] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path(percentEncoded: false))) ?? []
        return names.sorted().flatMap { profile -> [BrowserExtension] in
            guard let data = try? Data(contentsOf: profiles.appending(path: "\(profile)/extensions.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = json["addons"] as? [[String: Any]]
            else { return [] }
            // Only what the user installed: Firefox's own built-in add-ons live elsewhere.
            return addons.filter { $0["type"] as? String == "extension" && $0["location"] as? String == "app-profile" }.compactMap { addon in
                guard let identifier = addon["id"] as? String else { return nil }
                let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? identifier
                // Profile folders are "abcd1234.default-release"; the part after the dot is the readable one.
                let readable = profile.split(separator: ".", maxSplits: 1).last.map(String.init) ?? profile
                return BrowserExtension(
                    browser: .firefox, profile: readable, identifier: identifier, name: name, version: addon["version"] as? String,
                    icon: nil
                )
            }
        }
    }

    /// Safari's extensions come inside apps; removing the app removes them.
    func safariExtensions() -> [BrowserExtension] {
        ["com.apple.Safari.web-extension", "com.apple.Safari.extension"].flatMap { point in
            Self.parsePluginKit(LaunchControl.run(["-m", "-v", "-p", point], tool: "/usr/bin/pluginkit").output)
        }
    }

    /// Lines read `<id>(<version>)<TAB><uuid><TAB><date><TAB><path>`, sometimes after a `+` or `-`.
    static func parsePluginKit(_ output: String) -> [BrowserExtension] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let open = fields[0].firstIndex(of: "(") else { return nil }
            let identifier = String(fields[0][..<open]).trimmingCharacters(in: CharacterSet(charactersIn: "+-!= "))
            let version = fields[0][fields[0].index(after: open)...].dropLast().description
            let path = fields[3]
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] ?? [:]
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? identifier
            let app = path.range(of: ".app/").map { ((String(path[..<$0.lowerBound]) + ".app") as NSString).lastPathComponent }
            return BrowserExtension(
                browser: .safari, profile: app.map { ($0 as NSString).deletingPathExtension } ?? "", identifier: identifier,
                name: name, version: version.isEmpty ? nil : version, icon: nil
            )
        }
    }
}
