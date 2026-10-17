import CleanerCore
import SwiftUI

enum FilesTool: String, CaseIterable, Identifiable {
    case largeFiles, duplicates, diskMap

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .largeFiles: "Biggest & Old Files"
        case .duplicates: "Duplicates"
        case .diskMap: "Disk Map"
        }
    }
}

/// Drives the disk map: measure a folder once, then browse it level by level.
@Observable
final class DiskMapModel {
    enum Phase {
        case idle, scanning, ready
    }

    private(set) var phase = Phase.idle
    private(set) var root: DiskNode?
    /// From the scanned folder down to the one on screen.
    private(set) var path: [URL] = []
    private(set) var filesSeen = 0
    private(set) var isRemoving = false
    private(set) var lastReport: CleaningReport?
    private var task: Task<Void, Never>?

    var current: DiskNode? {
        guard let root, let last = path.last else { return root }
        return root.node(at: last)
    }

    /// The folders on the way to the current one, for the breadcrumb.
    var trail: [DiskNode] {
        guard let root else { return [] }
        return path.compactMap { root.node(at: $0) }
    }

    func scan(_ folder: URL) {
        task?.cancel()
        phase = .scanning
        filesSeen = 0
        lastReport = nil
        let scanner = DiskMapScanner()
        task = Task {
            let tree = await scanner.scan(folder) { count in
                Task { @MainActor [weak self] in self?.filesSeen = count }
            }
            guard !Task.isCancelled else { return }
            root = tree
            path = tree.map { [$0.url] } ?? []
            phase = tree == nil ? .idle : .ready
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = root == nil ? .idle : .ready
    }

    func open(_ node: DiskNode) {
        guard node.canOpen else { return }
        path.append(node.url)
    }

    func goBack(to node: DiskNode) {
        guard let index = path.firstIndex(of: node.url) else { return }
        path = Array(path.prefix(through: index))
    }

    /// Moves one entry to the Trash. It is the user's own pick, so it never gets deleted outright.
    func moveToTrash(_ node: DiskNode, with services: AppServices, method: DeletionMethod) async {
        guard root != nil else { return }
        let item = CleanableItem(
            url: node.url, name: node.name, category: .largeFiles, size: node.size, safety: .review,
            origin: .userSelection, root: node.url.deletingLastPathComponent()
        )
        isRemoving = true
        let report = await services.cleaner.clean([item], method: method)
        isRemoving = false
        lastReport = report
        if report.requestedMethod != .dryRun, report.removed.contains(where: { $0.item.url == node.url }) {
            root = root?.removing(node.url)
        }
    }
}

extension DiskNode {
    /// Folders open into a map of their own once they hold entries big enough to show.
    var canOpen: Bool { isDirectory && !children.isEmpty }
}
