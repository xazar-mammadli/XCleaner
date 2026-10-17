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
    case russian = "ru"
    case turkish = "tr"

    /// The language this copy of XCleaner started with. A change only shows after a restart.
    static let atLaunch = current

    /// The language saved in XCleaner's own preferences, or `.system` when none is.
    static var current: AppLanguage {
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
        guard let code = (saved as? [String])?.first else { return .system }
        if code.hasPrefix("az") { return .azerbaijani }
        if code.hasPrefix("ru") { return .russian }
        if code.hasPrefix("tr") { return .turkish }
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

/// Starts XCleaner again: after a change of language, and after an update.
enum AppRelauncher {
    /// Starts a new copy of XCleaner from the same place, then quits this one. If the new copy doesn't start, this one
    /// stays open and `failed` runs.
    static func relaunch(failed: @escaping @MainActor @Sendable () -> Void = {}) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, _ in
            let started = app != nil
            Task { @MainActor in
                guard started else { return failed() }
                NSApp.terminate(nil)
                // Still here: macOS doesn't quit while a sheet is open, such as the update sheet that asked for the
                // relaunch. The new copy is already running, so this one ends now.
                exit(0)
            }
        }
    }

    /// At launch: asks a copy of XCleaner that started this one, such as the version an update just replaced, to quit.
    /// Versions before 1.1.1 can't quit while their update sheet is open, so one that is still running a moment later
    /// is made to.
    static func closePreviousCopy() {
        let current = NSRunningApplication.current
        let place = (Bundle.main.bundleURL.path(percentEncoded: false) as NSString).standardizingPath
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { app in
                app.processIdentifier != current.processIdentifier
                    && (app.bundleURL?.path(percentEncoded: false)).map { ($0 as NSString).standardizingPath } == place
                    && (app.launchDate ?? .distantFuture) < (current.launchDate ?? .now)
            }
        guard !previous.isEmpty else { return }
        previous.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(3))
            previous.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }
}
