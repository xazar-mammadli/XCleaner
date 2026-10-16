import CleanerCore
import SwiftUI

/// Drives the Cleanup section: scan, review, clean, report.
@Observable
final class CleanupModel {
    enum Phase {
        case idle, scanning, review, cleaning, finished
    }

    struct Group: Identifiable {
        enum Kind: String, CaseIterable, Identifiable {
            case junk, system, downloads, mail, trash
            var id: Self { self }
        }

        let kind: Kind
        var isScanning = true
        /// The user stopped the scan before this group finished.
        var wasStopped = false
        var items: [CleanableItem] = []
        var issues: Set<ScanIssue> = []
        /// What the scan has found so far, while it runs.
        var progress: ScanProgress?

        var id: Kind { kind }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
        /// Found so far while scanning, or the final total afterwards.
        var liveBytes: Int64 { isScanning ? progress?.bytesFound ?? 0 : totalBytes }
    }

    private(set) var phase = Phase.idle
    private(set) var groups: [Group] = []
    private(set) var selection: Set<URL> = []
    private(set) var report: CleaningReport?
    /// The folder or item a scan looked at most recently.
    private(set) var currentLocation: String?
    private(set) var cleaningProgress: CleaningProgress?
    private(set) var cleaningMethod: DeletionMethod?
    private var task: Task<Void, Never>?

    var allItems: [CleanableItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanableItem] { allItems.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var foundBytes: Int64 { groups.reduce(0) { $0 + $1.liveBytes } }

    func scan(with services: AppServices) {
        task?.cancel()
        phase = .scanning
        report = nil
        selection = []
        currentLocation = nil
        groups = Group.Kind.allCases.map { Group(kind: $0) }

        let context = services.context
        let junkProgress = progressReporter(for: .junk)
        let systemProgress = progressReporter(for: .system)
        let downloadsProgress = progressReporter(for: .downloads)
        let mailProgress = progressReporter(for: .mail)
        let trashProgress = progressReporter(for: .trash)
        task = Task {
            await withTaskGroup(of: (Group.Kind, ScanResult).self) { scans in
                scans.addTask { (.junk, await JunkScanner().scan(context, progress: junkProgress)) }
                scans.addTask { (.system, await JunkScanner(rules: CleanupRule.system).scan(context, progress: systemProgress)) }
                scans.addTask { (.downloads, await DownloadsScanner().scan(context, progress: downloadsProgress)) }
                scans.addTask { (.mail, await MailAttachmentsScanner().scan(context, progress: mailProgress)) }
                scans.addTask { (.trash, await TrashScanner().scan(context, progress: trashProgress)) }
                for await (kind, result) in scans {
                    finish(kind, with: result)
                }
            }
            if !Task.isCancelled { phase = .review }
        }
    }

    /// Stops scanning but keeps what the finished groups found, so they can still be reviewed and cleaned.
    func cancel() {
        task?.cancel()
        task = nil
        for index in groups.indices where groups[index].isScanning {
            groups[index].isScanning = false
            groups[index].wasStopped = true
        }
        if groups.contains(where: { !$0.items.isEmpty }) {
            phase = .review
        } else {
            reset()
        }
    }

    func reset() {
        phase = .idle
        groups = []
        selection = []
        report = nil
    }

    func clean(with services: AppServices, method: DeletionMethod) async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        cleaningMethod = method
        cleaningProgress = CleaningProgress(
            completed: 0, total: items.count, completedBytes: 0, totalBytes: items.reduce(0) { $0 + $1.size }, currentItem: nil
        )
        phase = .cleaning
        report = await Administrator.clean(items, with: services.cleaner, method: method) { progress in
            Task { @MainActor [weak self] in self?.updateCleaning(progress) }
        }
        phase = .finished
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        selection.contains(item.url)
    }

    func setSelected(_ selected: Bool, _ item: CleanableItem) {
        if selected {
            selection.insert(item.url)
        } else {
            selection.remove(item.url)
        }
    }

    /// Progress arrives from the scan's own thread and is applied here, on the main actor.
    private func progressReporter(for kind: Group.Kind) -> ScanProgressHandler {
        { progress in
            Task { @MainActor [weak self] in self?.update(progress, for: kind) }
        }
    }

    private func update(_ progress: ScanProgress, for kind: Group.Kind) {
        guard let index = groups.firstIndex(where: { $0.kind == kind }), groups[index].isScanning else { return }
        groups[index].progress = progress
        if let location = progress.location { currentLocation = location }
    }

    private func updateCleaning(_ progress: CleaningProgress) {
        // Updates can arrive late or out of order; only ever move forward, and only while cleaning.
        guard phase == .cleaning, progress.completed >= cleaningProgress?.completed ?? 0 else { return }
        cleaningProgress = progress
    }

    private func finish(_ kind: Group.Kind, with result: ScanResult) {
        // A stopped scan can still deliver late results; they no longer belong on screen.
        guard !Task.isCancelled, let index = groups.firstIndex(where: { $0.kind == kind }) else { return }
        groups[index].items = result.items.sorted { $0.size > $1.size }
        groups[index].issues = result.issues
        groups[index].isScanning = false
        selection.formUnion(result.items.filter(\.isSelectedByDefault).map(\.url))
    }
}

extension CleanupModel.Group.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .junk: "System Junk"
        case .system: "System-Level Junk"
        case .downloads: "Installers & Downloads"
        case .mail: "Mail Attachments"
        case .trash: "Trash Bins"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .junk: "Caches, logs and developer files that apps recreate when they need them."
        case .system: "Caches and old logs that apps leave in the system folders. Removing them asks for your password, so pick them yourself."
        case .downloads: "Installers, unpacked archives, old screenshots and forgotten downloads. These go to the Trash."
        case .mail: "Copies Mail saved when you opened attachments. The originals stay in your mail."
        case .trash: "Items already in the Trash. Removing them deletes them for good."
        }
    }

    var systemImage: String {
        switch self {
        case .junk: "sparkles"
        case .system: "gearshape.2"
        case .downloads: "shippingbox"
        case .mail: "paperclip"
        case .trash: "trash"
        }
    }
}
