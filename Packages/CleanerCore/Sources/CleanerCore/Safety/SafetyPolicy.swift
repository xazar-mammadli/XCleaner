import Foundation

/// Where XCleaner may and may not remove things. All paths are absolute and canonical.
public struct SafetyPolicy: Sendable {
    /// Nothing inside these folders, or the folders themselves, is ever removed.
    public var neverDeleteTrees: [String]
    /// Folders that are never removed themselves, though items inside them may be.
    public var protectedContainers: [String]
    /// The user's personal folders. Cleanup rules never reach into them, and items the user picks there only go to the Trash.
    public var personalTrees: [String]
    /// Package types whose insides stay untouched. Changing anything inside an app breaks its code signature.
    public var sealedPackageExtensions: Set<String>
    /// Locations the user asked XCleaner to leave alone. They are neither scanned nor removed.
    public var excludedPaths: [String]

    public init(
        neverDeleteTrees: [String],
        protectedContainers: [String],
        personalTrees: [String],
        sealedPackageExtensions: Set<String>,
        excludedPaths: [String] = []
    ) {
        self.neverDeleteTrees = neverDeleteTrees
        self.protectedContainers = protectedContainers
        self.personalTrees = personalTrees
        self.sealedPackageExtensions = sealedPackageExtensions
        self.excludedPaths = excludedPaths
    }

    /// The policy XCleaner runs with for the given home folder and the user's exclusions.
    public static func standard(home: URL, excluding excluded: [URL] = []) -> SafetyPolicy {
        let homePath = canonical(home)
        func inHome(_ relative: String) -> String { homePath + "/" + relative }

        let personal = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"].map(inHome)

        return SafetyPolicy(
            neverDeleteTrees: [
                // macOS itself
                "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/dev", "/opt",
                "/private/etc", "/private/var/db", "/private/var/folders", "/private/var/vm", "/private/var/root",
                "/Library/Apple", "/Library/Keychains", "/Library/Security",
                "/Library/Application Support/com.apple.TCC",
                "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
                // Data that cannot be recreated
                inHome("Library/Keychains"),
                inHome("Library/Mobile Documents"), // iCloud Drive
                inHome("Library/CloudStorage"), // Dropbox, Google Drive, OneDrive…
                inHome("Library/Mail"),
                inHome("Library/Messages"),
                inHome("Library/Application Support/AddressBook"),
                inHome("Library/Calendars"),
                inHome("Library/Group Containers/group.com.apple.notes"),
                inHome("Library/Accounts"),
                inHome("Pictures/Photos Library.photoslibrary"),
                // XCleaner's own record of what it removed
                inHome("Library/Logs/XCleaner"),
            ]
                // Keys, tokens and passwords that command-line tools keep in hidden files
                + credentialPaths.map(inHome),
            protectedContainers: [
                "/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/tmp",
                "/Library/Application Support", "/Library/Caches", "/Library/LaunchAgents", "/Library/LaunchDaemons",
                "/Library/Logs", "/Library/Preferences", "/private/var/log",
                homePath,
                inHome(".Trash"), inHome("Applications"), inHome("Library"),
                inHome("Library/Application Support"), inHome("Library/Caches"), inHome("Library/Containers"),
                inHome("Library/Group Containers"), inHome("Library/LaunchAgents"), inHome("Library/Logs"),
                inHome("Library/Preferences"),
            ] + personal,
            personalTrees: personal,
            sealedPackageExtensions: ["app", "photoslibrary"],
            excludedPaths: excluded.map(canonical)
        )
    }

    /// Where command-line tools keep keys, tokens and passwords, relative to the home folder.
    public static let credentialPaths = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".password-store", ".netrc", ".git-credentials", ".npmrc", ".pypirc",
        ".docker/config.json", ".gem/credentials", ".config/gcloud", ".config/gh",
    ]

    private static func canonical(_ url: URL) -> String {
        PathUtilities.realPath(url.path(percentEncoded: false))
            ?? PathUtilities.joined(PathUtilities.components(of: url.standardizedFileURL.path(percentEncoded: false)))
    }
}
