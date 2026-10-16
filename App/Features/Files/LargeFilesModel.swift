import CleanerCore
import SwiftUI

/// Drives "Biggest & Old Files": scan the home folder, filter, move picked files to the Trash.
@Observable
final class LargeFilesModel {
    enum Phase {
        case idle, scanning, results
    }

    static let sizeOptions: [Int64] = [50_000_000, 100_000_000, 500_000_000, 1_000_000_000]

    private(set) var phase = Phase.idle
    private(set) var items: [CleanableItem] = []
    private(set) var issues: Set<ScanIssue> = []
    private(set) var filesSeen = 0
    private(set) var scannedMinimum: Int64 = 0
    private(set) var isRemoving = false
    private(set) var removalProgress: CleaningProgress?
    private(set) var lastReport: CleaningReport?
    private(set) var selection: Set<URL> = []
    var minimumSize: Int64 = 100_000_000
    var kindFilter: FileKind?
    private var task: Task<Void, Never>?

    var visibleItems: [CleanableItem] {
        items.filter { $0.size >= minimumSize && (kindFilter == nil || $0.kind == kindFilter) }
    }

    var selectedItems: [CleanableItem] { visibleItems.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Smaller files than the last scan looked for need a new scan.
    var needsRescan: Bool { phase == .results && minimumSize < scannedMinimum }

    func scan(with services: AppServices) {
        task?.cancel()
        phase = .scanning
        items = []
        issues = []
        selection = []
        filesSeen = 0
        lastReport = nil
        scannedMinimum = minimumSize

        let context = services.context
        let scanner = LargeFileScanner(minimumSize: minimumSize)
        task = Task {
            let result = await scanner.scan(context) { count in
                Task { @MainActor [weak self] in self?.filesSeen = count }
            }
            guard !Task.isCancelled else { return }
            items = result.items
            issues = result.issues
            phase = .results
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func moveSelectedToTrash(with services: AppServices, method: DeletionMethod) async {
        let picked = selectedItems
        guard !picked.isEmpty else { return }
        isRemoving = true
        removalProgress = nil
        let report = await services.cleaner.clean(picked, method: method) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isRemoving else { return }
                self.removalProgress = progress
            }
        }
        if report.requestedMethod != .dryRun {
            let removed = Set(report.removed.map(\.item.url))
            items.removeAll { removed.contains($0.url) }
            selection.subtract(removed)
        }
        lastReport = report
        isRemoving = false
        removalProgress = nil
    }

    func binding(for item: CleanableItem) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(item.url) },
            set: { isSelected in
                if isSelected { self.selection.insert(item.url) } else { self.selection.remove(item.url) }
            }
        )
    }
}
