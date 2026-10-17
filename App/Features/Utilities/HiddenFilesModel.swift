import CleanerCore
import SwiftUI

/// Drives Hidden Files: Finder's setting to show them, the hidden items of a folder, searching by name, and showing,
/// hiding or removing one.
@Observable
final class HiddenFilesModel {
    private(set) var items: [HiddenItem] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// Search results, while there is a search.
    private(set) var results: [HiddenItem]?
    private(set) var isSearching = false
    private(set) var lastReport: CleaningReport?
    /// An item whose hidden flag macOS didn't let XCleaner change.
    private(set) var flagFailure: String?
    private(set) var finderShowsHiddenItems = HiddenFlag.finderShowsHiddenItems
    private(set) var folder = URL.homeDirectory
    var query = ""

    var isHomeFolder: Bool { folder.standardizedFileURL == URL.homeDirectory.standardizedFileURL }

    func load(with services: AppServices) {
        isLoading = true
        lastReport = nil
        let scanner = HiddenFileScanner(folder: folder, home: .homeDirectory, safety: services.cleaner.safety)
        Task {
            items = await Task.detached(priority: .userInitiated) { scanner.topLevel() }.value
            hasLoaded = true
            isLoading = false
        }
    }

    func choose(_ folder: URL, with services: AppServices) {
        self.folder = folder
        results = nil
        load(with: services)
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Task { await search(with: services) }
        }
    }

    func search(with services: AppServices) async {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            results = nil
            return
        }
        isSearching = true
        let scanner = HiddenFileScanner(folder: folder, home: .homeDirectory, safety: services.cleaner.safety)
        let found = await Task.detached(priority: .userInitiated) { scanner.search(needle) }.value
        // A newer search may have started meanwhile.
        guard needle == query.trimmingCharacters(in: .whitespaces) else { return }
        results = found
        isSearching = false
    }

    func setHidden(_ hidden: Bool, _ item: HiddenItem, with services: AppServices) {
        flagFailure = nil
        do {
            try HiddenFlag.setHidden(hidden, at: item.url, safety: services.cleaner.safety)
            let changed = item.withHiddenFlag(hidden)
            items = items.map { $0.url == item.url ? changed : $0 }
            results = results?.map { $0.url == item.url ? changed : $0 }
        } catch {
            flagFailure = item.name
        }
    }

    func moveToTrash(_ item: HiddenItem, with services: AppServices, method: DeletionMethod) async {
        let report = await services.cleaner.clean([item.cleanableItem], method: method)
        lastReport = report
        if report.requestedMethod != .dryRun, !report.removed.isEmpty {
            items.removeAll { $0.url == item.url }
            results?.removeAll { $0.url == item.url || $0.url.path(percentEncoded: false).hasPrefix(item.url.path(percentEncoded: false) + "/") }
        }
    }

    func setFinderShowsHiddenItems(_ show: Bool) {
        HiddenFlag.setFinderShowsHiddenItems(show)
        finderShowsHiddenItems = HiddenFlag.finderShowsHiddenItems
    }

    /// Reads Finder's setting again, which can change in Terminal or another app.
    func refreshFinderSetting() {
        finderShowsHiddenItems = HiddenFlag.finderShowsHiddenItems
    }
}

extension HiddenItem {
    static let notedNames: Set<String> = [
        "Library", ".npm", ".cache", ".gradle", ".m2", ".cocoapods", ".cargo", ".rustup", ".nvm", ".pyenv", ".vscode", ".oh-my-zsh",
        ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".zsh_history", ".bash_history", ".zsh_sessions",
        ".bash_sessions", ".gitconfig", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".local", ".android",
        ".CFUserTextEncoding",
    ]

    /// Whether `note` says what it holds.
    var hasNote: Bool { Self.notedNames.contains(name) }

    /// What a well-known hidden item holds.
    var note: LocalizedStringResource {
        switch name {
        case "Library": "Settings, caches and data of your apps"
        case ".npm": "Packages npm downloaded, kept for reuse"
        case ".cache": "Caches of command-line tools"
        case ".gradle": "Gradle's caches and settings"
        case ".m2": "Libraries Maven downloaded, and its settings"
        case ".cocoapods": "CocoaPods' copy of its library index"
        case ".cargo": "Rust packages and tools"
        case ".rustup": "Rust toolchains"
        case ".nvm": "Node.js versions installed with nvm"
        case ".pyenv": "Python versions installed with pyenv"
        case ".vscode": "Visual Studio Code extensions"
        case ".oh-my-zsh": "Oh My Zsh, add-ons for your shell"
        case ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile": "Settings of your shell in Terminal"
        case ".zsh_history", ".bash_history": "Commands you typed in Terminal"
        case ".zsh_sessions", ".bash_sessions": "Terminal sessions macOS saved"
        case ".gitconfig": "Your Git settings"
        case ".ssh": "Your SSH keys"
        case ".gnupg": "Your GnuPG keys"
        case ".aws", ".azure", ".kube": "Sign-ins and settings of cloud tools"
        case ".docker": "Docker's settings and sign-ins"
        case ".config": "Settings of command-line tools"
        case ".local": "Programs and data of command-line tools"
        case ".android": "Android emulators and settings"
        case ".CFUserTextEncoding": "Your text encoding, kept by macOS"
        default: "Hidden item"
        }
    }
}
