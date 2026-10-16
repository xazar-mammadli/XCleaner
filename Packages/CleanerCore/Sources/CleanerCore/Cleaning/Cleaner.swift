import Foundation

/// What happened in one cleanup run.
public struct CleaningReport: Sendable {
    public struct Removed: Sendable {
        public let item: CleanableItem
        public let method: DeletionMethod
    }

    public struct Blocked: Sendable {
        public let item: CleanableItem
        public let reason: BlockReason
    }

    public struct Failed: Sendable {
        public let item: CleanableItem
        public let message: String
    }

    public let requestedMethod: DeletionMethod
    public internal(set) var removed: [Removed] = []
    public internal(set) var blocked: [Blocked] = []
    public internal(set) var failed: [Failed] = []
    public internal(set) var wasCancelled = false

    public init(requestedMethod: DeletionMethod) {
        self.requestedMethod = requestedMethod
    }

    /// Bytes deleted or moved to the Trash, or that would have been in a dry run.
    public var removedBytes: Int64 { bytes(where: { _ in true }) }
    /// Bytes moved to the Trash. That space only comes back once the Trash is emptied.
    public var trashedBytes: Int64 { bytes(where: { $0 == .moveToTrash }) }
    /// Bytes deleted for good, which are free again right away.
    public var deletedBytes: Int64 { bytes(where: { $0 == .deletePermanently }) }

    /// Combines the reports of several runs, such as the regular items and the Trash's own items.
    public mutating func append(_ other: CleaningReport) {
        removed += other.removed
        blocked += other.blocked
        failed += other.failed
        wasCancelled = wasCancelled || other.wasCancelled
    }

    private func bytes(where matches: (DeletionMethod) -> Bool) -> Int64 {
        removed.filter { matches($0.method) }.reduce(0) { $0 + $1.item.size }
    }
}

/// How far a cleanup run has come.
public struct CleaningProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    /// The item being handled right now; nil once the run is over.
    public let currentItem: String?

    public init(completed: Int, total: Int, completedBytes: Int64, totalBytes: Int64, currentItem: String?) {
        self.completed = completed
        self.total = total
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentItem = currentItem
    }

    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// Removes items, and is the only code in XCleaner that may. Each item is checked again by `SafetyGuard`
/// right before it is touched, and every outcome is written to the audit log.
public struct Cleaner: Sendable {
    public let safety: SafetyGuard
    public let trash: any TrashHandling
    public let auditLog: AuditLog?

    public init(safety: SafetyGuard, trash: any TrashHandling = SystemTrash(), auditLog: AuditLog?) {
        self.safety = safety
        self.trash = trash
        self.auditLog = auditLog
    }

    /// `progress` hears about each item before it is touched, and once more when the run is over.
    public func clean(
        _ items: [CleanableItem],
        method: DeletionMethod,
        progress: (@Sendable (CleaningProgress) -> Void)? = nil
    ) async -> CleaningReport {
        var report = CleaningReport(requestedMethod: method)
        let totalBytes = items.reduce(0) { $0 + $1.size }
        var completedBytes: Int64 = 0
        var completed = 0
        defer {
            progress?(CleaningProgress(
                completed: completed, total: items.count, completedBytes: completedBytes, totalBytes: totalBytes, currentItem: nil
            ))
        }

        for item in items {
            guard !Task.isCancelled else {
                report.wasCancelled = true
                break
            }
            progress?(CleaningProgress(
                completed: completed, total: items.count, completedBytes: completedBytes, totalBytes: totalBytes,
                currentItem: item.name
            ))
            defer {
                completed += 1
                completedBytes += item.size
            }
            switch safety.evaluate(item.url, origin: item.origin, root: item.root) {
            case .blocked(let reason):
                report.blocked.append(.init(item: item, reason: reason))
                await auditLog?.record(.init(
                    action: .blocked, path: item.url.path(percentEncoded: false), bytes: item.size, detail: reason.code))
            case .allowed(let path, let trashOnly):
                let effective = Self.method(for: item, requested: method, trashOnly: trashOnly)
                do {
                    try remove(path, using: effective)
                    report.removed.append(.init(item: item, method: effective))
                    await auditLog?.record(.init(action: .init(effective), path: path, bytes: item.size))
                } catch {
                    report.failed.append(.init(item: item, message: error.localizedDescription))
                    await auditLog?.record(.init(
                        action: .failed, path: path, bytes: item.size, detail: error.localizedDescription))
                }
            }
        }
        return report
    }

    /// What will happen to `item` when `requested` is asked for, so the user can be told before confirming.
    public static func plannedMethod(for item: CleanableItem, requested: DeletionMethod) -> DeletionMethod {
        method(for: item, requested: requested, trashOnly: item.origin == .userSelection)
    }

    static func method(for item: CleanableItem, requested: DeletionMethod, trashOnly: Bool) -> DeletionMethod {
        switch requested {
        case .dryRun:
            .dryRun
        case .moveToTrash:
            // Moving something that is already in the Trash to the Trash would do nothing: emptying it is the point.
            item.category == .trash && !trashOnly ? .deletePermanently : .moveToTrash
        case .deletePermanently:
            trashOnly ? .moveToTrash : .deletePermanently
        }
    }

    private func remove(_ path: String, using method: DeletionMethod) throws {
        switch method {
        case .dryRun:
            break
        case .moveToTrash:
            try trash.moveToTrash(URL(filePath: path))
        case .deletePermanently:
            // Removes a symlink itself, never what it points to.
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
