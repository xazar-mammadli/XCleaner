import AppKit
import CleanerCore
import SwiftUI

/// Drives Browser Data: what each browser keeps, and clearing the kinds the user picks while that browser is closed.
@Observable
final class BrowserDataModel {
    private(set) var items: [BrowserDataItem] = []
    private(set) var issues: Set<ScanIssue> = []
    private(set) var hasScanned = false
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var selection: Set<String> = []
    private(set) var lastReport: CleaningReport?
    /// Browsers running right now, by bundle identifier. Their files are in use, so they wait until the browser quits.
    private(set) var running: Set<String> = []

    var browsers: [Browser] {
        Array(Set(items.map(\.browser))).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var selectedItems: [BrowserDataItem] {
        items.filter { selection.contains($0.id) && !$0.isEmpty && !running.contains($0.browser.bundleIdentifier) }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func items(of browser: Browser) -> [BrowserDataItem] {
        let order = BrowserDataItem.Kind.allCases
        return items.filter { $0.browser == browser }.sorted {
            order.firstIndex(of: $0.kind) ?? 0 < order.firstIndex(of: $1.kind) ?? 0
        }
    }

    func isRunning(_ browser: Browser) -> Bool {
        running.contains(browser.bundleIdentifier)
    }

    func scan(hasFullDiskAccess: Bool) {
        guard !isScanning else { return }
        isScanning = true
        let home = URL.homeDirectory
        Task {
            let (items, issues) = await Task.detached(priority: .userInitiated) {
                BrowserDataScanner(home: home).scan(hasFullDiskAccess: hasFullDiskAccess)
            }.value
            self.items = items
            self.issues = issues
            // Caches are only a speed-up; history and cookies are the user's to pick.
            selection = Set(items.filter { $0.kind == .cache && !$0.isEmpty }.map(\.id))
            refreshRunning()
            isScanning = false
            hasScanned = true
        }
    }

    func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .intersection(items.map(\.browser.bundleIdentifier))
    }

    func binding(for item: BrowserDataItem) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(item.id) },
            set: { isSelected in
                if isSelected { self.selection.insert(item.id) } else { self.selection.remove(item.id) }
            }
        )
    }

    func quit(_ browser: Browser) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier) {
            app.terminate()
        }
    }

    func clean(with services: AppServices, method: DeletionMethod) async {
        let picked = selectedItems
        guard !picked.isEmpty else { return }
        isCleaning = true
        lastReport = await services.cleaner.clean(picked.flatMap(\.cleanableItems), method: method)
        isCleaning = false
        scan(hasFullDiskAccess: services.context.hasFullDiskAccess)
    }
}

extension BrowserDataItem.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .cache: "Cache"
        case .history: "History"
        case .cookies: "Cookies"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .cache: "Copies of pages and images. Sites load a little slower the first time afterwards."
        case .history: "Pages you visited and files you downloaded, and the suggestions built from them."
        case .cookies: "What websites stored, sign-ins included. Clearing them signs you out of websites."
        }
    }
}
