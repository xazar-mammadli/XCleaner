import Foundation

/// Work only root may do. XCleaner starts its own executable with administrator rights for a single run, after macOS
/// asks the user for their password, and hands it one of these. Nothing keeps running afterwards, and nothing in the
/// request is trusted: `PrivilegedRunner` checks every part of it again, as root.
public enum PrivilegedRequest: Codable, Sendable, Equatable {
    /// Removes items from the system folders in `PrivilegedRunner.removableRoots`.
    case remove(paths: [String], method: DeletionMethod, owner: TrashOwner)
    /// Turns a launch daemon from `/Library/LaunchDaemons` on or off, for now and after restarts.
    case setDaemon(label: String, enabled: Bool, plist: String)
}

/// The user whose Trash receives what is moved there. Their home folder must belong to them.
public struct TrashOwner: Codable, Sendable, Equatable {
    public let uid: UInt32
    public let gid: UInt32
    public let home: String

    public init(uid: UInt32, gid: UInt32, home: String) {
        self.uid = uid
        self.gid = gid
        self.home = home
    }

    /// The user running this process.
    public static var current: TrashOwner {
        TrashOwner(uid: getuid(), gid: getgid(), home: URL.homeDirectory.path(percentEncoded: false))
    }
}

public struct PrivilegedResponse: Codable, Sendable, Equatable {
    public struct Outcome: Codable, Sendable, Equatable {
        public enum Result: String, Codable, Sendable {
            case removed, blocked, failed
        }

        public let path: String
        public let result: Result
        /// How it went, for removed items.
        public let method: DeletionMethod?
        public let bytes: Int64
        /// The block reason's code, or the error.
        public let detail: String?
    }

    public var outcomes: [Outcome]
    /// Whether the request as a whole worked; a removal reports per item instead.
    public var succeeded: Bool
    public var message: String?

    public init(outcomes: [Outcome] = [], succeeded: Bool = true, message: String? = nil) {
        self.outcomes = outcomes
        self.succeeded = succeeded
        self.message = message
    }

    /// Every item failed with `message`: the run never happened, or it couldn't be read back.
    public static func failure(for items: [CleanableItem], message: String) -> PrivilegedResponse {
        PrivilegedResponse(
            outcomes: items.map { .init(path: $0.url.path(percentEncoded: false), result: .failed, method: nil, bytes: $0.size, detail: message) },
            succeeded: false, message: message
        )
    }

    /// The outcome as a report on `items`, the ones that were asked for.
    public func report(for items: [CleanableItem], requestedMethod: DeletionMethod) -> CleaningReport {
        var report = CleaningReport(requestedMethod: requestedMethod)
        let byPath = Dictionary(items.map { ($0.url.path(percentEncoded: false), $0) }, uniquingKeysWith: { first, _ in first })
        for outcome in outcomes {
            guard let item = byPath[outcome.path] else { continue }
            switch outcome.result {
            case .removed: report.removed.append(.init(item: item, method: outcome.method ?? requestedMethod))
            case .blocked: report.blocked.append(.init(item: item, reason: BlockReason(code: outcome.detail ?? "") ?? .outsideAllowedRoot))
            case .failed: report.failed.append(.init(item: item, message: outcome.detail ?? ""))
            }
        }
        return report
    }

    /// Writes every outcome to the user's history, which the root run could not do itself.
    public func record(in log: AuditLog) async {
        for outcome in outcomes {
            let action: AuditLog.Entry.Action = switch outcome.result {
            case .removed: .init(outcome.method ?? .deletePermanently)
            case .blocked: .blocked
            case .failed: .failed
            }
            await log.record(.init(action: action, path: outcome.path, bytes: outcome.bytes, detail: outcome.detail))
        }
    }
}

/// Carries out a `PrivilegedRequest` inside the root run.
public enum PrivilegedRunner {
    /// The only folders a privileged run removes anything from, whatever the request says: system caches and logs,
    /// launch items, and the folders of system-wide add-ons.
    public static let removableRoots =
        ["/Library/Caches", "/Library/Logs", "/private/var/log", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        + ExtensionScanner.systemFolders

    public static func perform(_ request: PrivilegedRequest) async -> PrivilegedResponse {
        switch request {
        case let .remove(paths, method, owner):
            await remove(paths, method: method, owner: owner)
        case let .setDaemon(label, enabled, plist):
            setDaemon(label: label, enabled: enabled, plist: plist)
        }
    }

    static func remove(
        _ paths: [String], method: DeletionMethod, owner: TrashOwner, roots: [String] = removableRoots, policy: SafetyPolicy? = nil
    ) async -> PrivilegedResponse {
        guard method == .dryRun || method == .deletePermanently || OwnersTrash.isUsable(owner) else {
            return PrivilegedResponse(succeeded: false, message: "The Trash of \(owner.home) can't be used.")
        }
        var response = PrivilegedResponse()
        var items: [CleanableItem] = []
        for path in paths {
            guard let root = allowedRoot(for: path, among: roots) else {
                response.outcomes.append(.init(path: path, result: .blocked, method: nil, bytes: 0, detail: BlockReason.outsideAllowedRoot.code))
                continue
            }
            let url = URL(filePath: path)
            items.append(CleanableItem(
                url: url, category: .systemCaches, size: DirectorySizer.allocatedSize(of: url).bytes, safety: .safe,
                origin: .rule, root: URL(filePath: root)
            ))
        }
        let cleaner = Cleaner(
            safety: SafetyGuard(policy: policy ?? .standard(home: URL(filePath: owner.home))), trash: OwnersTrash(owner: owner),
            auditLog: nil
        )
        let report = await cleaner.clean(items, method: method)
        response.outcomes += report.removed.map {
            .init(path: $0.item.url.path(percentEncoded: false), result: .removed, method: $0.method, bytes: $0.item.size, detail: nil)
        }
        response.outcomes += report.blocked.map {
            .init(path: $0.item.url.path(percentEncoded: false), result: .blocked, method: nil, bytes: $0.item.size, detail: $0.reason.code)
        }
        response.outcomes += report.failed.map {
            .init(path: $0.item.url.path(percentEncoded: false), result: .failed, method: nil, bytes: $0.item.size, detail: $0.message)
        }
        return response
    }

    /// The allowed folder `path` sits strictly inside, after symlinks are resolved, or `nil`.
    static func allowedRoot(for path: String, among roots: [String]) -> String? {
        guard path.hasPrefix("/"), let canonical = PathUtilities.canonicalItemPath(of: URL(filePath: path)) else { return nil }
        let parts = PathUtilities.components(of: canonical)
        return roots.first { root in
            let rootParts = PathUtilities.components(of: root)
            return parts.count > rootParts.count && PathUtilities.isWithin(parts, rootParts, ignoringCase: false)
        }
    }

    static func setDaemon(label: String, enabled: Bool, plist: String) -> PrivilegedResponse {
        guard label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let canonical = PathUtilities.realPath(plist),
              (canonical as NSString).deletingLastPathComponent == "/Library/LaunchDaemons"
        else { return PrivilegedResponse(succeeded: false, message: "Not a launch daemon: \(label)") }
        let target = "\(LaunchControl.systemDomain)/\(label)"
        if enabled {
            guard LaunchControl.run(["enable", target]).status == 0 else { return PrivilegedResponse(succeeded: false) }
            // Start it now as well; this fails harmlessly when it's loaded already.
            _ = LaunchControl.run(["bootstrap", LaunchControl.systemDomain, canonical])
        } else {
            guard LaunchControl.run(["disable", target]).status == 0 else { return PrivilegedResponse(succeeded: false) }
            _ = LaunchControl.run(["bootout", target])
        }
        return PrivilegedResponse()
    }
}

/// Moves items into a user's Trash and hands them over to that user, so they can empty it without a password.
struct OwnersTrash: TrashHandling {
    let owner: TrashOwner

    /// A real home folder of that user, with a Trash folder that is theirs and not a link elsewhere.
    static func isUsable(_ owner: TrashOwner) -> Bool {
        var home = stat()
        var trash = stat()
        return lstat(owner.home, &home) == 0 && home.st_mode & S_IFMT == S_IFDIR && home.st_uid == owner.uid
            && lstat(owner.home + "/.Trash", &trash) == 0 && trash.st_mode & S_IFMT == S_IFDIR && trash.st_uid == owner.uid
    }

    func moveToTrash(_ url: URL) throws -> URL? {
        let trash = URL(filePath: owner.home).appending(path: ".Trash", directoryHint: .isDirectory)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var destination = trash.appending(path: url.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = trash.appending(path: "\(name) \(number)\(ext)")
            number += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        giveToOwner(destination.path(percentEncoded: false))
        return destination
    }

    /// Changes ownership of the item and everything inside it, never following links.
    private func giveToOwner(_ path: String) {
        _ = lchown(path, owner.uid, owner.gid)
        guard let walker = FileManager.default.enumerator(atPath: path) else { return }
        for case let relative as String in walker {
            _ = lchown(path + "/" + relative, owner.uid, owner.gid)
        }
    }
}

extension BlockReason {
    /// Reads back what `code` wrote.
    public init?(code: String) {
        let (name, value) = code.firstIndex(of: ":").map { (String(code[..<$0]), String(code[code.index(after: $0)...])) } ?? (code, "")
        switch name {
        case "notAFileURL": self = .notAFileURL
        case "doesNotExist": self = .doesNotExist
        case "unresolvablePath": self = .unresolvablePath
        case "protectedLocation": self = .protectedLocation(value)
        case "protectedContainer": self = .protectedContainer(value)
        case "personalData": self = .personalData(value)
        case "insideSealedPackage": self = .insideSealedPackage(value)
        case "excludedByUser": self = .excludedByUser(value)
        case "volumeRoot": self = .volumeRoot
        case "outsideAllowedRoot": self = .outsideAllowedRoot
        default: return nil
        }
    }
}

extension CleanableItem {
    /// Whether removing it needs administrator rights: it was found in one of the system folders.
    public var needsAdministrator: Bool {
        let rootPath = PathUtilities.realPath(root.path(percentEncoded: false)) ?? root.path(percentEncoded: false)
        return PrivilegedRunner.removableRoots.contains(rootPath)
    }
}
