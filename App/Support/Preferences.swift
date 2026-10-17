import AppKit
import CleanerCore

enum PreferenceKey {
    static let removalMethod = "removalMethod"
    static let testMode = "testMode"
    static let hasSeenAccessGuide = "hasSeenAccessGuide"
    static let excludedPaths = "excludedPaths"
    static let showsMenuBarMonitor = "showsMenuBarMonitor"
    static let checksForUpdates = "checksForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let skippedVersion = "skippedVersion"
}

enum Preferences {
    /// Test Mode is for developing XCleaner: debug builds have it and start in it, so nothing is ever removed while
    /// XCleaner itself is being worked on. Release builds have no Test Mode at all.
    #if DEBUG
    static let hasTestMode = true
    static let defaultTestMode = true
    #else
    static let hasTestMode = false
    static let defaultTestMode = false
    #endif

    /// Whether XCleaner looks for a newer release once a day, as set under Settings › General. On unless turned off.
    static var checksForUpdates: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.checksForUpdates) as? Bool ?? true
    }

    /// How removals happen right now, as set under Settings › Safety.
    static var deletionMethod: DeletionMethod {
        let defaults = UserDefaults.standard
        if hasTestMode, defaults.object(forKey: PreferenceKey.testMode) as? Bool ?? defaultTestMode { return .dryRun }
        let removal = defaults.string(forKey: PreferenceKey.removalMethod).flatMap(RemovalMethod.init(rawValue:)) ?? .trash
        return removal == .trash ? .moveToTrash : .deletePermanently
    }
}

/// What happens to the items the user removes.
enum RemovalMethod: String {
    case trash
    case delete
}

enum AppLanguage: String {
    case system
    case english = "en"
    case azerbaijani = "az"

    /// The language this copy of XCleaner started with. A change only shows after a restart.
    static let atLaunch = current

    /// The language saved in XCleaner's own preferences, or `.system` when none is.
    static var current: AppLanguage {
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
        guard let code = (saved as? [String])?.first else { return .system }
        if code.hasPrefix("az") { return .azerbaijani }
        if code.hasPrefix("en") { return .english }
        return .system
    }

    /// The language XCleaner shows when it follows the system, named in that language ("English", "Azərbaycan").
    static var systemLanguageName: String {
        let systemPreferences = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? [String]
        let code = Bundle.preferredLocalizations(
            from: Bundle.main.localizations, forPreferences: systemPreferences ?? Locale.preferredLanguages
        ).first ?? "en"
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    /// macOS reads this the next time XCleaner launches.
    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
