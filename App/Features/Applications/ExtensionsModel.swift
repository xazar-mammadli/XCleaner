import AppKit
import CleanerCore
import SwiftUI

/// Drives Extensions: add-ons for macOS, which can be removed, and browser extensions, which are listed.
@Observable
final class ExtensionsModel {
    private(set) var items: [ExtensionItem] = []
    private(set) var browserExtensions: [BrowserExtension] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isRemoving = false
    private(set) var lastReport: CleaningReport?

    var isEmpty: Bool { items.isEmpty && browserExtensions.isEmpty }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        let home = URL.homeDirectory
        Task {
            let (items, browserExtensions) = await Task.detached(priority: .userInitiated) {
                (ExtensionScanner(home: home).extensions(), BrowserExtensionScanner(home: home).extensions())
            }.value
            self.items = items
            self.browserExtensions = browserExtensions
            isLoading = false
            hasLoaded = true
        }
    }

    /// Picked by the user, so they only ever go to the Trash. Those installed for everyone ask for the password.
    func remove(_ extensions: [ExtensionItem], with services: AppServices, method: DeletionMethod) async {
        let cleanable = extensions.map {
            CleanableItem(
                url: $0.url, name: $0.name, category: .appData, size: $0.size, safety: .review, origin: .userSelection, root: $0.folder
            )
        }
        isRemoving = true
        lastReport = await Administrator.clean(cleanable, with: services.cleaner, method: method)
        isRemoving = false
        load()
    }
}

extension ExtensionItem.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .preferencePane: "Preference Panes"
        case .quickLook: "Quick Look Plug-ins"
        case .spotlight: "Spotlight Plug-ins"
        case .screenSaver: "Screen Savers"
        case .internetPlugIn: "Internet Plug-ins"
        case .audioPlugIn: "Audio Plug-ins"
        case .service: "Services"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .preferencePane: "Extra panels in System Settings."
        case .quickLook: "Previews for more kinds of files. Recent macOS no longer loads this older kind."
        case .spotlight: "Teach Spotlight to search inside more kinds of files."
        case .screenSaver: "Screen savers you added."
        case .internetPlugIn: "Browser plug-ins of the past. Today's browsers no longer load them."
        case .audioPlugIn: "Effects, instruments and audio devices for music and calling apps."
        case .service: "Quick Actions in the Services menu and in Finder."
        }
    }
}
