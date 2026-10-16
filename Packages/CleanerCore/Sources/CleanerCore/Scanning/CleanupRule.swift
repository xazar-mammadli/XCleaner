import Foundation

/// One place where junk collects: a folder whose children are offered for removal.
public struct CleanupRule: Sendable {
    public var category: CleanupCategory
    /// The folder, relative to the home folder.
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
        appleSafety: SafetyLevel? = nil
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
    }

    func offers(_ name: String) -> Bool {
        if let only { return only.contains(name) }
        return !name.hasPrefix(".") && !skip.contains(name.lowercased())
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
}
