import CleanerCore
import SwiftUI

enum ApplicationsTool: String, CaseIterable, Identifiable {
    case uninstaller, remainingFiles

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .uninstaller: "Uninstaller"
        case .remainingFiles: "Remaining Files"
        }
    }
}

/// Drives the Uninstaller: the list of apps, the files the selected one keeps, and removing them.
@Observable
final class UninstallerModel {
    enum Action {
        case uninstall, reset
    }

    struct Outcome {
        let action: Action
        let appName: String
        let report: CleaningReport
    }

    enum Order: String, CaseIterable, Identifiable {
        case name, largestFirst

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .name: "Name"
            case .largestFirst: "Largest first"
            }
        }
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var sizes: [URL: Int64] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    var searchText = ""
    var order = Order.name
    private(set) var selectedApp: InstalledApp?
    /// The bundle first, then the app's data in the Library.
    private(set) var files: [CleanableItem] = []
    private(set) var fileIssues: Set<ScanIssue> = []
    private(set) var isFindingFiles = false
    private(set) var selection: Set<URL> = []
    private(set) var isRemoving = false
    private(set) var progress: CleaningProgress?
    private(set) var outcome: Outcome?
    private var sizeTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?

    var visibleApps: [InstalledApp] {
        let matching = searchText.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
        switch order {
        case .name:
            // The inventory lists apps by name already.
            return matching
        case .largestFirst:
            // Apps still being measured go last, by name.
            return matching.sorted { first, second in
                let firstSize = sizes[first.url] ?? -1
                let secondSize = sizes[second.url] ?? -1
                guard firstSize == secondSize else { return firstSize > secondSize }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        }
    }

    var isMeasuringSizes: Bool { hasLoaded && apps.contains { sizes[$0.url] == nil } }

    var selectedItems: [CleanableItem] { files.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var isBundleSelected: Bool { selectedItems.contains { $0.category == .application } }
    var selectedLeftovers: [CleanableItem] { selectedItems.filter { $0.category != .application } }

    func load(with services: AppServices) {
        guard !isLoading else { return }
        isLoading = true
        let inventory = AppInventory.standard(home: services.context.home)
        let ownIdentifier = Bundle.main.bundleIdentifier ?? ""
        Task {
            apps = await Task.detached { inventory.apps(excluding: [ownIdentifier]) }.value
            isLoading = false
            hasLoaded = true
            measureSizes()
        }
    }

    func select(_ app: InstalledApp?, with services: AppServices) {
        guard app?.url != selectedApp?.url else { return }
        selectedApp = app
        outcome = nil
        files = []
        selection = []
        fileIssues = []
        filesTask?.cancel()
        guard let app else { return }

        isFindingFiles = true
        let context = services.context
        let knownSize = sizes[app.url]
        filesTask = Task {
            let (bundleSize, leftovers) = await Task.detached {
                (knownSize ?? DirectorySizer.allocatedSize(of: app.url).bytes, LeftoverFinder().leftovers(of: app, context: context))
            }.value
            guard !Task.isCancelled, selectedApp?.url == app.url else { return }
            let order = Dictionary(uniqueKeysWithValues: LibraryLocation.allCases.enumerated().map { ($1, $0) })
            let sorted = leftovers.items.sorted {
                let left = order[$0.location ?? .applicationSupport] ?? 0
                let right = order[$1.location ?? .applicationSupport] ?? 0
                return left == right ? $0.size > $1.size : left < right
            }
            files = [app.asItem(size: bundleSize)] + sorted
            fileIssues = leftovers.issues
            selection = Set(files.filter(\.isSelectedByDefault).map(\.url))
            isFindingFiles = false
        }
    }

    func perform(_ action: Action, with services: AppServices, method: DeletionMethod) async {
        guard let app = selectedApp else { return }
        let items = action == .uninstall ? selectedItems : selectedLeftovers
        guard !items.isEmpty else { return }

        isRemoving = true
        progress = nil
        let report = await services.cleaner.clean(items, method: method) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isRemoving else { return }
                self.progress = progress
            }
        }
        isRemoving = false
        progress = nil
        outcome = Outcome(action: action, appName: app.name, report: report)

        guard report.requestedMethod != .dryRun else { return }
        let removed = Set(report.removed.map(\.item.url))
        files.removeAll { removed.contains($0.url) }
        selection.subtract(removed)
        if removed.contains(app.url) {
            apps.removeAll { $0.url == app.url }
            sizes[app.url] = nil
            selectedApp = nil
            files = []
        }
    }

    func binding(for item: CleanableItem) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(item.url) },
            set: { isSelected in
                if isSelected { self.selection.insert(item.url) } else { self.selection.remove(item.url) }
            }
        )
    }

    /// Sizes are measured in the background, one app at a time, so the list appears right away.
    private func measureSizes() {
        sizeTask?.cancel()
        let pending = apps.filter { sizes[$0.url] == nil }
        sizeTask = Task {
            for app in pending {
                guard !Task.isCancelled else { return }
                let url = app.url
                sizes[url] = await Task.detached(priority: .utility) { DirectorySizer.allocatedSize(of: url).bytes }.value
            }
        }
    }
}

/// Drives Remaining Files: data left behind by apps that are no longer installed.
@Observable
final class RemainingFilesModel {
    enum Phase {
        case idle, scanning, results
    }

    private(set) var phase = Phase.idle
    private(set) var groups: [OrphanGroup] = []
    private(set) var issues: Set<ScanIssue> = []
    private(set) var selection: Set<URL> = []
    var expanded: Set<String> = []
    private(set) var isRemoving = false
    private(set) var progress: CleaningProgress?
    private(set) var lastReport: CleaningReport?

    var allItems: [CleanableItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanableItem] { allItems.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var foundBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }

    func scan(with services: AppServices) {
        guard phase != .scanning else { return }
        phase = .scanning
        selection = []
        let context = services.context
        let inventory = AppInventory.standard(home: context.home)
        Task {
            let (found, problems) = await Task.detached {
                await OrphanFinder().scan(context, installedApps: inventory.apps())
            }.value
            groups = found
            issues = problems
            phase = .results
        }
    }

    func removeSelected(with services: AppServices, method: DeletionMethod) async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        isRemoving = true
        progress = nil
        let report = await services.cleaner.clean(items, method: method) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isRemoving else { return }
                self.progress = progress
            }
        }
        isRemoving = false
        progress = nil
        lastReport = report
        guard report.requestedMethod != .dryRun else { return }
        let removed = Set(report.removed.map(\.item.url))
        groups = groups.compactMap { group in
            let remaining = group.items.filter { !removed.contains($0.url) }
            return remaining.isEmpty ? nil : OrphanGroup(bundleIdentifier: group.bundleIdentifier, items: remaining)
        }
        selection.subtract(removed)
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
