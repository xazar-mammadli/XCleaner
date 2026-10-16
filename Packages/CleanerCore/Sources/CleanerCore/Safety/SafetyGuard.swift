import Foundation

public enum BlockReason: Sendable, Equatable {
    case notAFileURL
    case doesNotExist
    case unresolvablePath
    case protectedLocation(String)
    case protectedContainer(String)
    case personalData(String)
    case insideSealedPackage(String)
    case excludedByUser(String)
    case volumeRoot
    case outsideAllowedRoot

    /// A stable, non-localized code for the audit log.
    public var code: String {
        switch self {
        case .notAFileURL: "notAFileURL"
        case .doesNotExist: "doesNotExist"
        case .unresolvablePath: "unresolvablePath"
        case .protectedLocation(let path): "protectedLocation:\(path)"
        case .protectedContainer(let path): "protectedContainer:\(path)"
        case .personalData(let path): "personalData:\(path)"
        case .insideSealedPackage(let path): "insideSealedPackage:\(path)"
        case .excludedByUser(let path): "excludedByUser:\(path)"
        case .volumeRoot: "volumeRoot"
        case .outsideAllowedRoot: "outsideAllowedRoot"
        }
    }
}

public enum SafetyVerdict: Sendable, Equatable {
    /// Removable. Act on `path`, the canonical path that was checked, and never delete permanently when `trashOnly` is set.
    case allowed(path: String, trashOnly: Bool)
    case blocked(BlockReason)
}

/// The gate every removal passes through. It looks at the item as it is on disk right now,
/// so call it immediately before acting, and act only on the path it returns.
public struct SafetyGuard: Sendable {
    public let policy: SafetyPolicy
    private let neverDelete: [[String]]
    private let containers: [[String]]
    private let personal: [[String]]
    private let excluded: [[String]]

    public init(policy: SafetyPolicy) {
        self.policy = policy
        neverDelete = policy.neverDeleteTrees.map(PathUtilities.components(of:))
        containers = policy.protectedContainers.map(PathUtilities.components(of:))
        personal = policy.personalTrees.map(PathUtilities.components(of:))
        excluded = policy.excludedPaths.map(PathUtilities.components(of:))
    }

    /// Decides whether `url` may be removed. `root` is the folder the item was found in; the item must be strictly inside it.
    public func evaluate(_ url: URL, origin: ItemOrigin, root: URL) -> SafetyVerdict {
        guard url.isFileURL else { return .blocked(.notAFileURL) }
        guard let path = PathUtilities.canonicalItemPath(of: url) else { return .blocked(.unresolvablePath) }

        var item = stat()
        guard lstat(path, &item) == 0 else {
            return .blocked(errno == ENOENT ? .doesNotExist : .unresolvablePath)
        }
        let parts = PathUtilities.components(of: path)

        // Letter case is ignored on purpose: on a case-insensitive disk "/system" is "/System". Over-matching only blocks more.
        if let hit = neverDelete.first(where: { PathUtilities.isWithin(parts, $0, ignoringCase: true) }) {
            return .blocked(.protectedLocation(PathUtilities.joined(hit)))
        }
        if let hit = containers.first(where: { $0.count == parts.count && PathUtilities.isWithin(parts, $0, ignoringCase: true) }) {
            return .blocked(.protectedContainer(PathUtilities.joined(hit)))
        }
        if let hit = excluded.first(where: { PathUtilities.isWithin(parts, $0, ignoringCase: true) }) {
            return .blocked(.excludedByUser(PathUtilities.joined(hit)))
        }

        var parent = stat()
        guard stat((path as NSString).deletingLastPathComponent, &parent) == 0 else { return .blocked(.unresolvablePath) }
        if parent.st_dev != item.st_dev { return .blocked(.volumeRoot) }

        if let package = parts.dropLast().firstIndex(where: {
            policy.sealedPackageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }) {
            return .blocked(.insideSealedPackage(PathUtilities.joined(Array(parts[...package]))))
        }
        if origin == .rule, let hit = personal.first(where: { PathUtilities.isWithin(parts, $0, ignoringCase: true) }) {
            return .blocked(.personalData(PathUtilities.joined(hit)))
        }

        // The root is compared case-sensitively: an unexpected spelling is refused rather than trusted.
        guard let rootPath = PathUtilities.realPath(root.path(percentEncoded: false)) else { return .blocked(.outsideAllowedRoot) }
        let rootParts = PathUtilities.components(of: rootPath)
        guard parts.count > rootParts.count, PathUtilities.isWithin(parts, rootParts, ignoringCase: false) else {
            return .blocked(.outsideAllowedRoot)
        }
        return .allowed(path: path, trashOnly: origin == .userSelection)
    }

    /// Whether the user excluded `url`, so scans should not even offer it.
    public func isExcluded(_ url: URL) -> Bool {
        guard !excluded.isEmpty else { return false }
        let path = PathUtilities.canonicalItemPath(of: url) ?? url.standardizedFileURL.path(percentEncoded: false)
        return isExcluded(path: path)
    }

    /// The same check for a path that is already canonical, as file-system walks produce.
    public func isExcluded(path: String) -> Bool {
        guard !excluded.isEmpty else { return false }
        let parts = PathUtilities.components(of: path)
        return excluded.contains { PathUtilities.isWithin(parts, $0, ignoringCase: true) }
    }
}
