import Foundation
import SQLite3

/// Something private that macOS lets an app use only once the user allows it, under System Settings › Privacy & Security.
public enum PrivacyPermission: String, Sendable, CaseIterable {
    case camera = "kTCCServiceCamera"
    case microphone = "kTCCServiceMicrophone"
    case screenRecording = "kTCCServiceScreenCapture"
    case systemAudioRecording = "kTCCServiceAudioCapture"
    case accessibility = "kTCCServiceAccessibility"
    case inputMonitoring = "kTCCServiceListenEvent"
    case fullDiskAccess = "kTCCServiceSystemPolicyAllFiles"
    case desktopFolder = "kTCCServiceSystemPolicyDesktopFolder"
    case documentsFolder = "kTCCServiceSystemPolicyDocumentsFolder"
    case downloadsFolder = "kTCCServiceSystemPolicyDownloadsFolder"
    case networkVolumes = "kTCCServiceSystemPolicyNetworkVolumes"
    case removableVolumes = "kTCCServiceSystemPolicyRemovableVolumes"
    case otherAppsData = "kTCCServiceSystemPolicyAppData"
    case appManagement = "kTCCServiceSystemPolicyAppBundles"
    case automation = "kTCCServiceAppleEvents"
    case contacts = "kTCCServiceAddressBook"
    case calendars = "kTCCServiceCalendar"
    case reminders = "kTCCServiceReminders"
    case photos = "kTCCServicePhotos"
    case mediaLibrary = "kTCCServiceMediaLibrary"
    case speechRecognition = "kTCCServiceSpeechRecognition"
    case bluetooth = "kTCCServiceBluetoothAlways"
    case focus = "kTCCServiceFocusStatus"
    case developerTools = "kTCCServiceDeveloperTool"
    case passkeys = "kTCCServiceWebBrowserPublicKeyCredential"

    /// The name `tccutil` knows it by.
    public var serviceName: String { String(rawValue.dropFirst("kTCCService".count)) }

    /// Its page under System Settings › Privacy & Security.
    public var settingsURL: URL {
        let anchor: String? = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenRecording, .systemAudioRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .desktopFolder, .documentsFolder, .downloadsFolder, .networkVolumes, .removableVolumes: "Privacy_FilesAndFolders"
        case .otherAppsData: "Privacy_AppData"
        case .appManagement: "Privacy_AppBundles"
        case .automation: "Privacy_Automation"
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .photos: "Privacy_Photos"
        case .mediaLibrary: "Privacy_Media"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .bluetooth: "Privacy_Bluetooth"
        case .focus: "Privacy_Focus"
        case .developerTools: "Privacy_DevTools"
        case .passkeys: nil
        }
        let base = "x-apple.systempreferences:com.apple.preference.security"
        return URL(string: anchor.map { base + "?" + $0 } ?? base)!
    }
}

/// What the user answered when an app asked for a permission.
public struct PermissionGrant: Sendable, Hashable, Identifiable {
    public enum Client: Sendable, Hashable {
        case app(bundleIdentifier: String)
        /// A command-line tool or script, by its path.
        case tool(path: String)
    }

    public enum Decision: Sendable, Hashable {
        case allowed
        case denied
        /// Allowed in part, such as access to some photos only.
        case limited
    }

    public var id: String { "\(permission.rawValue)|\(clientKey)|\(target ?? "")" }
    public let permission: PrivacyPermission
    public let client: Client
    public let decision: Decision
    /// For Automation: the app it may control, by bundle identifier.
    public let target: String?
    public let lastChanged: Date?

    public init(permission: PrivacyPermission, client: Client, decision: Decision, target: String?, lastChanged: Date?) {
        self.permission = permission
        self.client = client
        self.decision = decision
        self.target = target
        self.lastChanged = lastChanged
    }

    var clientKey: String {
        switch client {
        case .app(let identifier): identifier
        case .tool(let path): path
        }
    }
}

/// Reads the permissions apps were given from macOS's privacy databases: the user's own one, and the one for the whole
/// Mac that holds screen recording, accessibility and Full Disk Access. Only reads: changes go through `tccutil` or
/// System Settings.
public struct PermissionReader: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// macOS keeps the databases closed without Full Disk Access.
        case accessDenied
        case unreadable
    }

    public let databases: [URL]

    public init(databases: [URL]) {
        self.databases = databases
    }

    public static func standard(home: URL) -> PermissionReader {
        PermissionReader(databases: [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
            URL(filePath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ])
    }

    public func read() -> Result<[PermissionGrant], Failure> {
        var grants: [PermissionGrant] = []
        var readAny = false
        for database in databases {
            switch Self.read(database) {
            case .success(let found):
                grants += found
                readAny = true
            case .failure(.accessDenied):
                return .failure(.accessDenied)
            case .failure(.unreadable):
                continue
            }
        }
        guard readAny else { return .failure(.unreadable) }
        // The same answer can sit in both databases; it is listed once.
        var seen = Set<String>()
        return .success(grants.filter { seen.insert($0.id).inserted })
    }

    /// Reads a private copy, so a database macOS is writing to right now is read whole, its recent changes included.
    static func read(_ database: URL) -> Result<[PermissionGrant], Failure> {
        let path = database.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return .failure(.unreadable) }
        guard FileManager.default.isReadableFile(atPath: path) else { return .failure(.accessDenied) }
        let copy = FileManager.default.temporaryDirectory.appending(path: "XCleaner-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try FileManager.default.copyItem(atPath: path + suffix, toPath: copy.appending(path: "TCC.db" + suffix).path(percentEncoded: false))
            }
        } catch {
            return .failure(isPermissionError(error) ? .accessDenied : .unreadable)
        }
        return query(copy.appending(path: "TCC.db").path(percentEncoded: false))
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(EPERM) || underlying.code == Int(EACCES))
    }

    static func query(_ path: String) -> Result<[PermissionGrant], Failure> {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            return .failure(.unreadable)
        }
        defer { sqlite3_close(connection) }

        // Columns came and went over the years; only those present are asked for.
        let columns = Set(rows(connection, "PRAGMA table_info(access)").compactMap { $0[1] })
        guard columns.isSuperset(of: ["service", "client", "client_type"]) else { return .failure(.unreadable) }
        let decision = columns.contains("auth_value") ? "auth_value" : columns.contains("allowed") ? "allowed * 2" : "NULL"
        let changed = columns.contains("last_modified") ? "last_modified" : "NULL"
        let target = columns.contains("indirect_object_identifier") ? "indirect_object_identifier" : "NULL"
        let sql = "SELECT service, client, client_type, \(decision), \(changed), \(target) FROM access"

        let grants = rows(connection, sql).compactMap { row -> PermissionGrant? in
            guard let service = row[0].flatMap(PrivacyPermission.init(rawValue:)), let client = row[1], !client.isEmpty,
                  let value = row[3].flatMap(Int.init)
            else { return nil }
            let decision: PermissionGrant.Decision
            switch value {
            case 0: decision = .denied
            case 2: decision = .allowed
            case 3: decision = .limited
            default: return nil
            }
            let target = row[5].flatMap { $0.isEmpty || $0 == "UNUSED" ? nil : $0 }
            return PermissionGrant(
                permission: service, client: row[2] == "1" ? .tool(path: client) : .app(bundleIdentifier: client),
                decision: decision, target: service == .automation ? target : nil,
                lastChanged: row[4].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            )
        }
        return .success(grants)
    }

    /// Every row of a query, with each column as text.
    private static func rows(_ connection: OpaquePointer, _ sql: String) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return result
    }
}

/// Makes macOS forget an app's answer, so the app asks again the next time it needs the permission.
public enum PermissionReset {
    /// Runs `tccutil reset`. Returns whether it reported success; read the permissions again to see the outcome.
    public static func reset(_ permission: PrivacyPermission, for bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { return false }
        return LaunchControl.run(["reset", permission.serviceName, bundleIdentifier], tool: "/usr/bin/tccutil").status == 0
    }
}
