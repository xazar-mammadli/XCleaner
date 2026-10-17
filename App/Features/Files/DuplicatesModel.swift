import CleanerCore
import SwiftUI

/// Drives Duplicates: compare the chosen folders, keep one copy of everything, move the other copies to the Trash,
/// and merge folders that share most of their files.
@Observable
final class DuplicatesModel {
    enum Phase {
        case idle, scanning, results
    }

    enum Kind: String, CaseIterable, Identifiable {
        case files, folders, similarFolders

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .files: "Files"
            case .folders: "Folders"
            case .similarFolders: "Similar Folders"
            }
        }
    }

    static let sizeOptions: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]

    private(set) var phase = Phase.idle
    private(set) var progress: DuplicateScanProgress?
    private(set) var result = DuplicateScanResult()
    /// Copies picked for removal, files and folders alike.
    private(set) var selection: Set<URL> = [] {
        didSet { goingFolders = result.folderGroups.flatMap(\.items).filter { selection.contains($0.url) } }
    }
    /// The picked folders, kept at hand: every row asks about them.
    private(set) var goingFolders: [DuplicateItem] = []
    private(set) var isWorking = false
    private(set) var removalProgress: CleaningProgress?
    private(set) var lastReport: CleaningReport?
    /// Picked copies the last removal left alone, so that a copy of everything stays.
    private(set) var lastSkipped = 0
    private(set) var lastMerge: FolderMerger.Report?
    var folders: [URL] = [URL.homeDirectory]
    var minimumSize: Int64 = 1_000_000
    var kind = Kind.files
    private var task: Task<Void, Never>?

    var groups: [DuplicateGroup] {
        switch kind {
        case .files: result.fileGroups
        case .folders: result.folderGroups
        case .similarFolders: []
        }
    }

    var allGroups: [DuplicateGroup] { result.fileGroups + result.folderGroups }

    /// What could be freed: every copy but one in each group.
    var extraBytes: Int64 { allGroups.reduce(0) { $0 + $1.extraSize } }

    var selectedItems: [DuplicateItem] {
        // A copy inside a picked folder goes with it and counts once.
        allGroups.flatMap(\.items).filter { item in selection.contains(item.url) && !goingFolders.contains { $0.contains(item) } }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.reclaimableSize } }

    func count(of kind: Kind) -> Int {
        switch kind {
        case .files: result.fileGroups.count
        case .folders: result.folderGroups.count
        case .similarFolders: result.similarFolders.count
        }
    }

    // MARK: Scanning

    func scan(with services: AppServices) {
        task?.cancel()
        phase = .scanning
        progress = nil
        result = DuplicateScanResult()
        selection = []
        lastReport = nil
        lastMerge = nil
        let scanner = DuplicateScanner(folders: folders, minimumSize: minimumSize)
        let context = services.context
        task = Task {
            let result = await scanner.scan(context) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .scanning else { return }
                    self.progress = progress
                }
            }
            guard !Task.isCancelled else { return }
            self.result = result
            kind = result.fileGroups.isEmpty && !result.folderGroups.isEmpty ? .folders : .files
            phase = .results
            smartSelect()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(url) {
            folders.append(url)
        }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: Picking copies

    /// Keeps the best copy of each group, on each disk, and picks the others. Folders go first, so the files inside a
    /// folder that goes are not the ones kept.
    func smartSelect() {
        let home = URL.homeDirectory
        var picked = Set<URL>()
        for group in result.folderGroups {
            let keep = SmartSelect.keepers(in: group, home: home)
            picked.formUnion(group.items.map(\.url).filter { !keep.contains($0) })
        }
        let goingFolders = result.folderGroups.flatMap(\.items).filter { picked.contains($0.url) }
        for group in result.fileGroups {
            let keep = SmartSelect.keepers(in: group, home: home) { item in goingFolders.contains { $0.contains(item) } }
            picked.formUnion(group.items.map(\.url).filter { !keep.contains($0) })
        }
        selection = picked
    }

    func deselectAll() {
        selection = []
    }

    /// One copy in each group always stays: the last one that isn't picked, or inside a picked folder, can't be picked.
    func canPick(_ item: DuplicateItem, in group: DuplicateGroup) -> Bool {
        group.items.contains { other in
            other.url != item.url && !selection.contains(other.url) && !goingFolders.contains { $0.contains(other) }
        }
    }

    func binding(for item: DuplicateItem, in group: DuplicateGroup) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(item.url) },
            set: { isPicked in
                if !isPicked {
                    self.selection.remove(item.url)
                } else if self.canPick(item, in: group) {
                    self.selection.insert(item.url)
                }
            }
        )
    }

    // MARK: Removing

    func removeSelected(with services: AppServices, method: DeletionMethod) async {
        let groups = allGroups
        let picked = selection
        guard !picked.isEmpty else { return }
        isWorking = true
        removalProgress = nil
        lastMerge = nil
        let plan = await Task.detached(priority: .userInitiated) { DuplicateRemoval.plan(removing: picked, in: groups) }.value
        let report = await services.cleaner.clean(plan.items, method: method) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isWorking else { return }
                self.removalProgress = progress
            }
        }
        lastReport = report
        lastSkipped = plan.skipped.count
        if method != .dryRun { prune() }
        isWorking = false
        removalProgress = nil
    }

    // MARK: Merging

    func plan(merging pair: SimilarFolders, keep: URL, with services: AppServices) async -> Result<FolderMerger.Plan, FolderMerger.Refusal> {
        let other = keep == pair.first ? pair.second : pair.first
        let safety = services.cleaner.safety
        return await Task.detached(priority: .userInitiated) { FolderMerger.plan(keep: keep, other: other, safety: safety) }.value
    }

    func merge(_ plan: FolderMerger.Plan, with services: AppServices, method: DeletionMethod) async {
        isWorking = true
        lastReport = nil
        lastMerge = await FolderMerger.merge(plan, cleaner: services.cleaner, method: method)
        if method != .dryRun { prune() }
        isWorking = false
    }

    /// Drops what is gone from the lists, and groups left with a single copy.
    private func prune() {
        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path(percentEncoded: false), &info) == 0
        }
        func pruned(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
            groups.compactMap { group in
                let items = group.items.filter { exists($0.url) }
                return items.count > 1 ? DuplicateGroup(id: group.id, items: items, length: group.length) : nil
            }
        }
        result.fileGroups = pruned(result.fileGroups)
        result.folderGroups = pruned(result.folderGroups)
        result.similarFolders = result.similarFolders.filter { exists($0.first) && exists($0.second) }
        selection.formIntersection(allGroups.flatMap(\.items).map(\.url))
    }
}
