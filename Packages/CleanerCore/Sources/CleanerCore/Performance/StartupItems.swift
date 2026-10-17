import Foundation

/// A job launchd starts on its own, read from its property list.
public struct LaunchItem: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Runs in the user's session: from `~/Library/LaunchAgents`, `/Library/LaunchAgents` or inside an app.
        case agent
        /// Runs for the whole Mac, as root: from `/Library/LaunchDaemons` or inside an app.
        case daemon
    }

    public enum Schedule: Sendable, Hashable {
        /// Starts at login, or at startup for a daemon.
        case atLaunch
        /// Kept running, and started again when it stops.
        case alwaysRunning
        /// Runs every so often.
        case periodically
        /// Starts only when something asks for it.
        case onDemand
    }

    public enum Problem: Sendable, Hashable {
        /// The file names no job or no program, so launchd has nothing to run.
        case empty
        /// The program it starts is gone, most often because its app was deleted.
        case programMissing
    }

    public var id: URL { plistURL }
    /// The job's name, or the file name when the file names none.
    public let label: String
    public let plistURL: URL
    public let kind: Kind
    /// Whether the file sits in the user's own `~/Library/LaunchAgents`, so the user can remove it.
    public let isUsers: Bool
    /// The app bundle it comes inside, for jobs an app registers itself (with `SMAppService`).
    public let bundledIn: URL?
    /// The program it runs.
    public let program: String?
    /// What it hands the program, the program itself first (`ProgramArguments`).
    public let arguments: [String]
    /// Apps the job says it belongs to (`AssociatedBundleIdentifiers`).
    public let bundleIdentifiers: [String]
    public let schedule: Schedule
    public let problem: Problem?
    /// Turned off in the file itself (`Disabled`).
    public let isDisabledInFile: Bool

    public init(
        label: String, plistURL: URL, kind: Kind, isUsers: Bool, bundledIn: URL?, program: String?, bundleIdentifiers: [String],
        schedule: Schedule, problem: Problem?, isDisabledInFile: Bool, arguments: [String] = []
    ) {
        self.label = label
        self.plistURL = plistURL
        self.kind = kind
        self.isUsers = isUsers
        self.bundledIn = bundledIn
        self.program = program
        self.arguments = arguments
        self.bundleIdentifiers = bundleIdentifiers
        self.schedule = schedule
        self.problem = problem
        self.isDisabledInFile = isDisabledInFile
    }
}

/// Lists the launch agents and daemons in the standard folders and inside apps.
public struct LaunchItemScanner: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// Jobs in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`.
    public func folderItems() -> [LaunchItem] {
        let folders: [(URL, LaunchItem.Kind, Bool)] = [
            (home.appending(path: "Library/LaunchAgents"), .agent, true),
            (URL(filePath: "/Library/LaunchAgents"), .agent, false),
            (URL(filePath: "/Library/LaunchDaemons"), .daemon, false),
        ]
        return folders.flatMap { folder, kind, isUsers in
            Self.plists(in: folder).compactMap { Self.read($0, kind: kind, isUsers: isUsers, bundledIn: nil) }
        }
    }

    /// Jobs that apps carry inside their bundles and register themselves. They only run once registered.
    public func bundledItems(in apps: [InstalledApp]) -> [LaunchItem] {
        apps.flatMap { app in
            [("Contents/Library/LaunchAgents", LaunchItem.Kind.agent), ("Contents/Library/LaunchDaemons", .daemon)]
                .flatMap { relative, kind in
                    Self.plists(in: app.url.appending(path: relative)).compactMap {
                        Self.read($0, kind: kind, isUsers: false, bundledIn: app.url)
                    }
                }
        }
    }

    static func plists(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "plist" }
    }

    static func read(_ url: URL, kind: LaunchItem.Kind, isUsers: Bool, bundledIn bundle: URL?) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A damaged or empty file is still listed, so it can be cleaned away.
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        let declaredLabel = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        if program == nil, let bundle, let relative = plist["BundleProgram"] as? String {
            program = bundle.appending(path: relative).path(percentEncoded: false)
        }
        let problem: LaunchItem.Problem? =
            if declaredLabel == nil || program == nil {
                .empty
            } else if let program, program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) {
                .programMissing
            } else {
                nil
            }
        return LaunchItem(
            label: declaredLabel ?? url.deletingPathExtension().lastPathComponent,
            plistURL: url,
            kind: kind,
            isUsers: isUsers,
            bundledIn: bundle,
            program: program,
            bundleIdentifiers: plist["AssociatedBundleIdentifiers"] as? [String] ?? [],
            schedule: schedule(of: plist),
            problem: problem,
            isDisabledInFile: plist["Disabled"] as? Bool ?? false,
            arguments: plist["ProgramArguments"] as? [String] ?? []
        )
    }

    static func schedule(of plist: [String: Any]) -> LaunchItem.Schedule {
        if let keepAlive = plist["KeepAlive"], keepAlive as? Bool == true || keepAlive is [String: Any] { return .alwaysRunning }
        if plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil { return .periodically }
        if plist["RunAtLoad"] as? Bool == true { return .atLaunch }
        return .onDemand
    }
}

/// A helper app that comes inside an app and opens at login once the app registers it (`Contents/Library/LoginItems`).
public struct LoginItem: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    /// The app it comes with.
    public let app: InstalledApp

    public static func items(in apps: [InstalledApp]) -> [LoginItem] {
        apps.flatMap { app in
            let folder = app.url.appending(path: "Contents/Library/LoginItems")
            let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return bundles.filter { $0.pathExtension == "app" }.compactMap { url -> LoginItem? in
                guard let helper = AppInventory.read(url) else { return nil }
                return LoginItem(url: url, name: helper.name, bundleIdentifier: helper.bundleIdentifier, app: app)
            }
        }
    }
}

/// Reads and changes launchd's state through `launchctl`. Nothing here needs a password: changes stay within the
/// user's own session.
public enum LaunchControl {
    /// The user's session.
    public static var userDomain: String { "gui/\(getuid())" }
    /// The whole Mac.
    public static let systemDomain = "system"

    /// Jobs turned on or off with launchctl or in System Settings: label → whether it is off.
    /// Jobs registered by apps show up here once registered.
    public static func overrides(in domain: String) -> [String: Bool] {
        parseOverrides(run(["print-disabled", domain]).output)
    }

    /// Jobs launchd has loaded: label → process ID, 0 while not running.
    public static func loadedJobs(in domain: String) -> [String: Int32] {
        parseServices(run(["print", domain]).output)
    }

    /// Turns a launch agent off or on in the user's session, for now and for later logins. Returns whether it worked.
    public static func setEnabled(_ enabled: Bool, label: String, plist: URL) -> Bool {
        let target = "\(userDomain)/\(label)"
        if enabled {
            guard run(["enable", target]).status == 0 else { return false }
            // Start it again now; this fails harmlessly when launchd already has it loaded.
            _ = run(["bootstrap", userDomain, plist.path(percentEncoded: false)])
        } else {
            guard run(["disable", target]).status == 0 else { return false }
            // Stop it now too; this fails harmlessly when it isn't loaded.
            _ = run(["bootout", target])
        }
        return true
    }

    /// Lines look like `"com.example.agent" => disabled`; older systems write `=> true`.
    static func parseOverrides(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            result[label] = state == "disabled" || state == "true"
        }
        return result
    }

    /// Inside `services = { … }`, lines read `<pid> <last exit status> <label>`.
    static func parseServices(_ output: String) -> [String: Int32] {
        var result: [String: Int32] = [:]
        var isInServices = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !isInServices {
                isInServices = trimmed == "services = {"
                continue
            }
            if trimmed == "}" { break }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }
            result[String(fields[2])] = pid
        }
        return result
    }

    /// Runs `launchctl`, or another of macOS's command-line tools, and returns its exit status and output.
    static func run(_ arguments: [String], tool: String = "/bin/launchctl") -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Everything that starts on its own, and launchd's view of it, read in one go.
public struct StartupSnapshot: Sendable {
    /// Login items the apps registered; helpers that were never registered don't start.
    public let loginItems: [LoginItem]
    /// Jobs in the standard folders, and jobs apps registered from inside their bundles.
    public let jobs: [LaunchItem]
    public let userOverrides: [String: Bool]
    public let systemOverrides: [String: Bool]
    public let userJobs: [String: Int32]
    public let systemJobs: [String: Int32]

    public init(
        loginItems: [LoginItem], jobs: [LaunchItem], userOverrides: [String: Bool], systemOverrides: [String: Bool],
        userJobs: [String: Int32], systemJobs: [String: Int32]
    ) {
        self.loginItems = loginItems
        self.jobs = jobs
        self.userOverrides = userOverrides
        self.systemOverrides = systemOverrides
        self.userJobs = userJobs
        self.systemJobs = systemJobs
    }

    /// Reads the folders, the apps and launchd. It runs `launchctl` and walks every app, so call it off the main thread.
    public static func read(home: URL, apps: [InstalledApp]) -> StartupSnapshot {
        let scanner = LaunchItemScanner(home: home)
        let userOverrides = LaunchControl.overrides(in: LaunchControl.userDomain)
        let systemOverrides = LaunchControl.overrides(in: LaunchControl.systemDomain)
        let bundled = scanner.bundledItems(in: apps).filter { item in
            (item.kind == .agent ? userOverrides : systemOverrides)[item.label] != nil
        }
        return StartupSnapshot(
            loginItems: LoginItem.items(in: apps).filter { userOverrides[$0.bundleIdentifier] != nil },
            jobs: (scanner.folderItems() + bundled).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending },
            userOverrides: userOverrides,
            systemOverrides: systemOverrides,
            userJobs: LaunchControl.loadedJobs(in: LaunchControl.userDomain),
            systemJobs: LaunchControl.loadedJobs(in: LaunchControl.systemDomain)
        )
    }

    /// Whether the job may start: on unless someone turned it off, with launchctl or System Settings or in its file.
    public func isOn(_ item: LaunchItem) -> Bool {
        guard item.problem == nil else { return false }
        if let isOff = (item.kind == .agent ? userOverrides : systemOverrides)[item.label] { return !isOff }
        return !item.isDisabledInFile
    }

    public func isRunning(_ item: LaunchItem) -> Bool {
        ((item.kind == .agent ? userJobs : systemJobs)[item.label] ?? 0) > 0
    }

    public func isOn(_ item: LoginItem) -> Bool {
        userOverrides[item.bundleIdentifier] == false
    }
}
