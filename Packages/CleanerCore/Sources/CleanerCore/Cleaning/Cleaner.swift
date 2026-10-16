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

    /// Bytes deleted or moved to the Trash, or that would have been in a dry run.
    public var removedBytes: Int64 { removed.reduce(0) { $0 + $1.item.size } }
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

    public func clean(_ items: [CleanableItem], method: DeletionMethod) async -> CleaningReport {
        var report = CleaningReport(requestedMethod: method)
        for item in items {
            guard !Task.isCancelled else {
                report.wasCancelled = true
                break
            }
            switch safety.evaluate(item.url, origin: item.origin, root: item.root) {
            case .blocked(let reason):
                report.blocked.append(.init(item: item, reason: reason))
                await auditLog?.record(.init(
                    action: .blocked, path: item.url.path(percentEncoded: false), bytes: item.size, detail: reason.code))
            case .allowed(let path, let trashOnly):
                let effective: DeletionMethod = trashOnly && method == .deletePermanently ? .moveToTrash : method
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
