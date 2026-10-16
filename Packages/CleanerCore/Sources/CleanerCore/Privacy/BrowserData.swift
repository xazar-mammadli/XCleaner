import Foundation

/// One kind of data a browser keeps, across all its profiles, and the files that hold it.
public struct BrowserDataItem: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Copies of pages and images that make sites load faster. Clearing them only makes sites load a little slower once.
        case cache
        /// Pages visited, files downloaded, and the suggestions the browser builds from them.
        case history
        /// What sites store in the browser, sign-ins included. Clearing them signs the user out of websites.
        case cookies
    }

    /// One file or folder to remove, with the folder it must stay inside.
    public struct Target: Sendable, Hashable {
        public let url: URL
        public let root: URL
    }

    public var id: String { "\(browser.bundleIdentifier)/\(kind.rawValue)" }
    public let browser: Browser
    public let kind: Kind
    public let targets: [Target]
    public let size: Int64

    /// Nothing to clear right now, as just after clearing: the browser makes the files again as it is used.
    public var isEmpty: Bool { size == 0 }

    /// The targets as items for `Cleaner`.
    public var cleanableItems: [CleanableItem] {
        targets.map {
            CleanableItem(
                url: $0.url, name: "\(browser.name): \($0.url.lastPathComponent)", category: .browserData,
                size: DirectorySizer.allocatedSize(of: $0.url).bytes, safety: .safe, origin: .rule, root: $0.root
            )
        }
    }
}

/// Finds what browsers keep about browsing. Passwords, autofill, bookmarks and the open tabs a browser restores are
/// never part of it, and neither is Firefox's history, which shares its file with the bookmarks.
public struct BrowserDataScanner: Sendable {
    /// Browsers built on Chromium: where their profiles and their caches live.
    static let chromium: [(browser: Browser, profiles: String, caches: String)] = [
        (.chrome, "Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome"),
        (.edge, "Library/Application Support/Microsoft Edge", "Library/Caches/Microsoft Edge"),
        (.brave, "Library/Application Support/BraveSoftware/Brave-Browser", "Library/Caches/BraveSoftware/Brave-Browser"),
        (.vivaldi, "Library/Application Support/Vivaldi", "Library/Caches/Vivaldi"),
        (.opera, "Library/Application Support/com.operasoftware.Opera", "Library/Caches/com.operasoftware.Opera"),
        (.arc, "Library/Application Support/Arc/User Data", "Library/Caches/Arc/User Data"),
        (.chromium, "Library/Application Support/Chromium", "Library/Caches/Chromium"),
    ]

    /// Files inside a Chromium profile, by kind. Their `-journal` companions go with them.
    static let chromiumFiles: [BrowserDataItem.Kind: [String]] = [
        .cache: [
            "GPUCache", "Code Cache", "DawnWebGPUCache", "DawnGraphiteCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache",
        ],
        .history: ["History", "Visited Links", "Top Sites", "Shortcuts", "Network Action Predictor"],
        .cookies: ["Cookies", "Network/Cookies", "Extension Cookies"],
    ]

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public func scan(hasFullDiskAccess: Bool) -> (items: [BrowserDataItem], issues: Set<ScanIssue>) {
        var items = Self.chromium.flatMap { chromiumItems($0.browser, profiles: $0.profiles, caches: $0.caches) } + firefoxItems()
        var issues = Set<ScanIssue>()
        // Safari's folders are guarded by macOS; without Full Disk Access, looking makes macOS ask the user.
        if hasFullDiskAccess {
            items += safariItems()
        } else if FileManager.default.fileExists(atPath: home.appending(path: "Library/Safari").path(percentEncoded: false)) {
            issues.insert(.accessDenied(home.appending(path: "Library/Safari").path(percentEncoded: false)))
        }
        return (items, issues)
    }

    func chromiumItems(_ browser: Browser, profiles relative: String, caches cachesRelative: String) -> [BrowserDataItem] {
        let root = home.appending(path: relative)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        var profiles = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted().map { root.appending(path: $0) }
        if profiles.isEmpty, exists(root.appending(path: "History")) { profiles = [root] }
        guard !profiles.isEmpty else { return [] }

        // Every kind is listed for a browser that is there, even when there is nothing to clear right now.
        return BrowserDataItem.Kind.allCases.map { kind in
            var targets = profiles.flatMap { profile in
                (Self.chromiumFiles[kind] ?? []).flatMap { name in
                    [name, name + "-journal"].map { profile.appending(path: $0) }.filter(exists).map {
                        BrowserDataItem.Target(url: $0, root: profile)
                    }
                }
            }
            if kind == .cache {
                // The disk cache itself lives in ~/Library/Caches, one folder per profile.
                let caches = home.appending(path: cachesRelative)
                targets += profiles.map { caches.appending(path: $0.lastPathComponent) }.filter(exists).map {
                    BrowserDataItem.Target(url: $0, root: caches)
                }
            }
            return item(browser, kind, targets)
        }
    }

    func firefoxItems() -> [BrowserDataItem] {
        let browser = Browser.firefox
        let profiles = home.appending(path: "Library/Application Support/Firefox/Profiles")
        let caches = home.appending(path: "Library/Caches/Firefox/Profiles")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path(percentEncoded: false))) ?? []).sorted()
        guard !names.isEmpty else { return [] }
        let cookies = names.flatMap { name in
            ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { profiles.appending(path: "\(name)/\($0)") }
                .filter(exists).map { BrowserDataItem.Target(url: $0, root: profiles.appending(path: name)) }
        }
        let cache = names.map { caches.appending(path: $0) }.filter(exists).map { BrowserDataItem.Target(url: $0, root: caches) }
        return [item(browser, .cache, cache), item(browser, .cookies, cookies)]
    }

    func safariItems() -> [BrowserDataItem] {
        let browser = Browser.safari
        let safari = home.appending(path: "Library/Safari")
        guard exists(safari) else { return [] }
        let container = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library")
        let history = ["History.db", "History.db-wal", "History.db-shm", "History.db-lock", "Downloads.plist"]
            .map { safari.appending(path: $0) }.filter(exists).map { BrowserDataItem.Target(url: $0, root: safari) }
        let cookieFolder = container.appending(path: "Cookies")
        let cookies = [cookieFolder.appending(path: "Cookies.binarycookies")].filter(exists).map {
            BrowserDataItem.Target(url: $0, root: cookieFolder)
        }
        let caches = home.appending(path: "Library/Caches")
        let containerCaches = container.appending(path: "Caches")
        let cache = [BrowserDataItem.Target(url: caches.appending(path: "com.apple.Safari"), root: caches)]
            + (((try? FileManager.default.contentsOfDirectory(atPath: containerCaches.path(percentEncoded: false))) ?? [])
                .filter { !$0.hasPrefix(".") }.map { BrowserDataItem.Target(url: containerCaches.appending(path: $0), root: containerCaches) })
        return [item(browser, .cache, cache.filter { exists($0.url) }), item(browser, .history, history), item(browser, .cookies, cookies)]
    }

    private func item(_ browser: Browser, _ kind: BrowserDataItem.Kind, _ targets: [BrowserDataItem.Target]) -> BrowserDataItem {
        let size = targets.reduce(Int64(0)) { $0 + DirectorySizer.allocatedSize(of: $1.url).bytes }
        return BrowserDataItem(browser: browser, kind: kind, targets: targets, size: size)
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }
}
