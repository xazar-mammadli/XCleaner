import Foundation

/// One place where junk collects: a folder whose children are offered for removal.
public struct CleanupRule: Sendable {
    public var category: CleanupCategory
    /// The folder, relative to the home folder, or an absolute path for the system folders.
    public var folder: String
    public var safety: SafetyLevel
    /// When set, only children with these exact names are offered.
    public var only: Set<String>?
    /// Children that are never offered, compared ignoring letter case.
    public var skip: Set<String>
    /// Children macOS guards with a permission prompt. They are only looked at with Full Disk Access.
    public var needsFullDiskAccess: Set<String>
    /// Bundle identifier of the app these files belong to. While it runs, its items are flagged and left unselected.
    public var owner: String?
    /// Shown instead of the child's own name, for rules with a single, cryptically named child.
    public var displayName: String?
    /// Children are named after bundle identifiers, as in `~/Library/Caches`, so app names can be looked up.
    public var childrenAreBundleIDs: Bool
    /// Overrides `safety` for Apple's own children (`com.apple.…`), which are left for the user to review.
    public var appleSafety: SafetyLevel?
    /// Leaves out Apple's own children (`com.apple.…`) altogether.
    public var skipsApple: Bool
    /// Offers only logs that were rotated out and archived (`system.log.0.gz`, `wifi.log.3.bz2`, `keybagd.log.0`).
    public var onlyArchives: Bool

    public init(
        category: CleanupCategory,
        folder: String,
        safety: SafetyLevel,
        only: Set<String>? = nil,
        skip: Set<String> = [],
        needsFullDiskAccess: Set<String> = [],
        owner: String? = nil,
        displayName: String? = nil,
        childrenAreBundleIDs: Bool = false,
        appleSafety: SafetyLevel? = nil,
        skipsApple: Bool = false,
        onlyArchives: Bool = false
    ) {
        self.category = category
        self.folder = folder
        self.safety = safety
        self.only = only
        self.skip = Set(skip.map { $0.lowercased() })
        self.needsFullDiskAccess = Set(needsFullDiskAccess.map { $0.lowercased() })
        self.owner = owner
        self.displayName = displayName
        self.childrenAreBundleIDs = childrenAreBundleIDs
        self.appleSafety = appleSafety
        self.skipsApple = skipsApple
        self.onlyArchives = onlyArchives
    }

    /// The folder itself, for the given home folder.
    public func location(in home: URL) -> URL {
        folder.hasPrefix("/") ? URL(filePath: folder, directoryHint: .isDirectory) : home.appending(path: folder)
    }

    func offers(_ name: String) -> Bool {
        if let only { return only.contains(name) }
        guard !name.hasPrefix("."), !skip.contains(name.lowercased()) else { return false }
        if skipsApple, name.lowercased().hasPrefix("com.apple.") { return false }
        if onlyArchives {
            let lowercased = name.lowercased()
            return ["gz", "bz2", "xz", "zip"].contains((lowercased as NSString).pathExtension)
                || lowercased.range(of: #"\.\d+$"#, options: .regularExpression) != nil
        }
        return true
    }

    public static let standard: [CleanupRule] = [
        CleanupRule(
            category: .userCaches, folder: "Library/Caches", safety: .safe,
            skip: [
                "com.xazar.xcleaner",
                // Sync and account state that is costly or risky to rebuild.
                "CloudKit", "com.apple.bird", "com.apple.cloudd", "com.apple.akd", "com.apple.nsurlsessiond",
                "com.apple.containermanagerd", "FamilyCircle", "familycircled", "com.apple.homed", "com.apple.HomeKit",
                "com.apple.ap.adprivacyd",
            ],
            needsFullDiskAccess: ["com.apple.Safari", "com.apple.Safari.SafeBrowsing"],
            childrenAreBundleIDs: true, appleSafety: .review
        ),
        CleanupRule(category: .logs, folder: "Library/Logs", safety: .safe, skip: ["XCleaner"]),
        CleanupRule(
            category: .developerJunk, folder: "Library/Developer/Xcode/DerivedData", safety: .safe,
            owner: "com.apple.dt.Xcode"
        ),
        CleanupRule(
            category: .developerJunk, folder: "Library/Developer/CoreSimulator/Caches", safety: .safe,
            owner: "com.apple.iphonesimulator"
        ),
        CleanupRule(
            category: .developerJunk, folder: "Library/Developer/Xcode/iOS DeviceSupport", safety: .review,
            owner: "com.apple.dt.Xcode"
        ),
        // Archives are needed to read crash reports of shipped builds.
        CleanupRule(
            category: .developerJunk, folder: "Library/Developer/Xcode/Archives", safety: .caution,
            owner: "com.apple.dt.Xcode"
        ),
        CleanupRule(category: .developerJunk, folder: ".npm", safety: .safe, only: ["_cacache"], displayName: "npm"),
        CleanupRule(category: .developerJunk, folder: ".gradle", safety: .review, only: ["caches"], displayName: "Gradle"),
    ]

    /// Caches and logs in the system folders. Only an administrator may remove them, so they are offered on their own
    /// and left unselected. Apple's own items stay: macOS looks after them, and protects many of them anyway.
    public static let system: [CleanupRule] = [
        CleanupRule(
            category: .systemCaches, folder: "/Library/Caches", safety: .safe, skip: ["ColorSync", "Desktop Pictures"], skipsApple: true
        ),
        CleanupRule(
            category: .systemLogs, folder: "/Library/Logs", safety: .safe,
            skip: [
                "CrashReporter", "DiagnosticReports", "WindowServer", "Xsan", "hidfw-crashlogs", "MCXTools.log", "LKDC-setup.log",
            ],
            skipsApple: true
        ),
        CleanupRule(category: .systemLogs, folder: "/private/var/log", safety: .safe, onlyArchives: true),
    ]
}
