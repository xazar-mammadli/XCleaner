import Foundation
import SQLite3
import Testing
@testable import CleanerCore

@Suite("App permissions")
struct PermissionTests {
    /// A database laid out like macOS's, in WAL mode and still open, so its rows sit in the WAL file as they do while
    /// macOS is using it. Close it after reading.
    private func database(at url: URL, rows: [(String, String, Int, Int, Int, String)]) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path(percentEncoded: false), &connection) == SQLITE_OK)
        let database = try #require(connection)
        sqlite3_wal_autocheckpoint(database, 0)
        let setup = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
                auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
                policy_id INTEGER, indirect_object_identifier_type INTEGER, indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
                indirect_object_code_identity BLOB, flags INTEGER, last_modified INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (service, client, client_type, indirect_object_identifier));
            """
        #expect(sqlite3_exec(database, setup, nil, nil, nil) == SQLITE_OK)
        for (service, client, type, value, modified, target) in rows {
            let insert = """
                INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
                    indirect_object_identifier, last_modified)
                VALUES ('\(service)', '\(client)', \(type), \(value), 2, 1, '\(target)', \(modified));
                """
            #expect(sqlite3_exec(database, insert, nil, nil, nil) == SQLITE_OK)
        }
        return database
    }

    @Test func readsAnswersFromBothDatabases() throws {
        let sandbox = try Sandbox()
        let userURL = sandbox.url("user/TCC.db")
        let systemURL = sandbox.url("system/TCC.db")
        let user = try database(at: userURL, rows: [
            ("kTCCServiceCamera", "us.zoom.xos", 0, 2, 1_700_000_000, "UNUSED"),
            ("kTCCServiceMicrophone", "/usr/local/bin/recorder", 1, 0, 1_700_000_100, "UNUSED"),
            ("kTCCServiceAppleEvents", "com.example.script", 0, 2, 1_700_000_200, "com.apple.finder"),
            ("kTCCServicePhotos", "com.example.photos", 0, 3, 0, "UNUSED"),
            // Not a permission the user decides on.
            ("kTCCServiceUbiquity", "com.example.cloud", 0, 2, 0, "UNUSED"),
            // Asked, never answered.
            ("kTCCServiceCamera", "com.example.waiting", 0, 1, 0, "UNUSED"),
        ])
        let system = try database(at: systemURL, rows: [
            ("kTCCServiceScreenCapture", "us.zoom.xos", 0, 2, 1_700_000_300, "UNUSED"),
            ("kTCCServiceSystemPolicyAllFiles", "com.xazar.xcleaner", 0, 2, 1_700_000_400, "UNUSED"),
        ])
        defer {
            sqlite3_close(user)
            sqlite3_close(system)
        }
        #expect(FileManager.default.fileExists(atPath: path(userURL) + "-wal"))

        let grants = try PermissionReader(databases: [userURL, systemURL]).read().get()
        #expect(grants.count == 6)
        let camera = try #require(grants.first { $0.permission == .camera })
        #expect(camera.client == .app(bundleIdentifier: "us.zoom.xos"))
        #expect(camera.decision == .allowed)
        #expect(camera.lastChanged == Date(timeIntervalSince1970: 1_700_000_000))
        let microphone = try #require(grants.first { $0.permission == .microphone })
        #expect(microphone.client == .tool(path: "/usr/local/bin/recorder"))
        #expect(microphone.decision == .denied)
        #expect(grants.first { $0.permission == .automation }?.target == "com.apple.finder")
        #expect(grants.first { $0.permission == .photos }?.decision == .limited)
        #expect(grants.contains { $0.permission == .screenRecording })
        #expect(grants.contains { $0.permission == .fullDiskAccess })
        // The private copies are gone again.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
        #expect(!leftovers.contains { $0.hasPrefix("XCleaner-permissions-") })
    }

    @Test func reportsWhatItCantRead() throws {
        let sandbox = try Sandbox()
        #expect(PermissionReader(databases: [sandbox.url("missing/TCC.db")]).read() == .failure(.unreadable))
        try sandbox.file("broken/TCC.db", contents: Data("not a database".utf8))
        #expect(PermissionReader(databases: [sandbox.url("broken/TCC.db")]).read() == .failure(.unreadable))
    }

    @Test func knowsEveryPermissionByItsServiceName() {
        #expect(PrivacyPermission.camera.serviceName == "Camera")
        #expect(PrivacyPermission.fullDiskAccess.serviceName == "SystemPolicyAllFiles")
        #expect(PrivacyPermission.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" })
        // Anything but a bundle identifier is refused before tccutil runs.
        #expect(!PermissionReset.reset(.camera, for: "--help"))
        #expect(!PermissionReset.reset(.camera, for: "a b"))
    }
}

extension PermissionReader.Failure: CustomStringConvertible {
    public var description: String { self == .accessDenied ? "accessDenied" : "unreadable" }
}
