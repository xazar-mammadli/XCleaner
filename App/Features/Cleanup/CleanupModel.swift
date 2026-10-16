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
            case junk, downloads, trash
            var id: Self { self }
        }

        let kind: Kind
        var isScanning = true
        /// The user stopped the scan before this group finished.
        var wasStopped = false
        var items: [CleanableItem] = []
        var issues: Set<ScanIssue> = []

        var id: Kind { kind }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    private(set) var phase = Phase.idle
    private(set) var groups: [Group] = []
    private(set) var selection: Set<URL> = []
    private(set) var report: CleaningReport?
    private var task: Task<Void, Never>?

    var allItems: [CleanableItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanableItem] { allItems.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var foundBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }

    func scan(with services: AppServices) {
        task?.cancel()
        phase = .scanning
        report = nil
        selection = []
        groups = Group.Kind.allCases.map { Group(kind: $0) }

        let context = services.context
        task = Task {
            await withTaskGroup(of: (Group.Kind, ScanResult).self) { scans in
                scans.addTask { (.junk, await JunkScanner().scan(context)) }
                scans.addTask { (.downloads, await DownloadsScanner().scan(context)) }
                scans.addTask { (.trash, await TrashScanner().scan(context)) }
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
        phase = .cleaning
        report = await services.cleaner.clean(items, method: method)
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
        case .downloads: "Installers & Downloads"
        case .trash: "Trash Bins"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .junk: "Caches, logs and developer files that apps recreate when they need them."
        case .downloads: "Installers, unpacked archives, old screenshots and forgotten downloads. These go to the Trash."
        case .trash: "Items already in the Trash. Removing them deletes them for good."
        }
    }

    var systemImage: String {
        switch self {
        case .junk: "sparkles"
        case .downloads: "shippingbox"
        case .trash: "trash"
        }
    }
}
