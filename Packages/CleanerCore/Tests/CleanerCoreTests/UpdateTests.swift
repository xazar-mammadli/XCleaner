import Foundation
import Security
import Testing
@testable import CleanerCore

@Suite("Updates")
struct UpdateTests {
    /// A tiny app: an Info.plist and a copy of /usr/bin/true, signed for this Mac only.
    private func app(_ relative: String, identifier: String = "com.example.tool", version: String, in sandbox: Sandbox) throws -> URL {
        let app = try sandbox.directory("\(relative)/Contents/MacOS")
            .deletingLastPathComponent().deletingLastPathComponent()
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Tool",
            "CFBundlePackageType": "APPL", "CFBundleName": "Tool",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/Tool"))
        try #require(LaunchControl.run(["--force", "--sign", "-", path(app)], tool: "/usr/bin/codesign").status == 0)
        return app
    }

    private func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        try #require(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        return try #require(requirement)
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    @Test func comparesVersionsNumberByNumber() throws {
        let current = try #require(AppVersion("1.9.9"))
        #expect(try #require(AppVersion("1.10.0")) > current)
        #expect(AppVersion("v2") == AppVersion("2.0.0"))
        #expect(AppVersion("1.0.0-beta.2") == AppVersion("1.0.0"))
        #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
    }

    @Test func readsTheLatestRelease() throws {
        let json = """
            {"tag_name": "v1.2.0", "name": "XCleaner 1.2.0", "body": "- Faster scans", "draft": false, "prerelease": false,
             "html_url": "https://github.com/xazar-mammadli/XCleaner/releases/tag/v1.2.0",
             "assets": [
               {"name": "XCleaner-1.2.0.dmg.sha256", "size": 90, "browser_download_url": "https://example.com/XCleaner-1.2.0.dmg.sha256"},
               {"name": "XCleaner-1.2.0.dmg", "size": 9000000, "browser_download_url": "https://example.com/XCleaner-1.2.0.dmg"}
             ]}
            """
        let release = try #require(ReleaseInfo.parse(Data(json.utf8)))
        #expect(release.version == AppVersion("1.2.0"))
        #expect(release.title == "XCleaner 1.2.0")
        #expect(release.notes == "- Faster scans")
        #expect(release.imageURL?.lastPathComponent == "XCleaner-1.2.0.dmg")
        #expect(release.imageSize == 9_000_000)
        let prerelease = json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        #expect(ReleaseInfo.parse(Data(prerelease.utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("{}".utf8)) == nil)
    }

    @Test func checksAnUpdateBeforeUsingIt() throws {
        let sandbox = try Sandbox()
        let current = try #require(AppVersion("1.0.0"))
        let ours = try requirement(#"identifier "com.example.tool""#)

        let good = try app("New/Tool.app", version: "1.1.0", in: sandbox)
        #expect(UpdateInstaller.verify(good, bundleIdentifier: "com.example.tool", newerThan: current, requirement: ours) == nil)

        // Someone else's app, an older version, or a signature the running copy doesn't accept.
        let other = try app("Other/Tool.app", identifier: "com.example.other", version: "2.0.0", in: sandbox)
        #expect(UpdateInstaller.verify(other, bundleIdentifier: "com.example.tool", newerThan: current, requirement: ours) == .wrongApp)
        let older = try app("Older/Tool.app", version: "0.9.0", in: sandbox)
        #expect(UpdateInstaller.verify(older, bundleIdentifier: "com.example.tool", newerThan: current, requirement: ours) == .wrongApp)
        let strangers = try requirement(#"identifier "com.example.tool" and anchor apple generic"#)
        #expect(UpdateInstaller.verify(good, bundleIdentifier: "com.example.tool", newerThan: current, requirement: strangers) == .signatureMismatch)

        // Changed after signing.
        let executable = good.appending(path: "Contents/MacOS/Tool")
        var bytes = try Data(contentsOf: executable)
        for page in stride(from: 0x4000, to: bytes.count - 0x300, by: 0x1000) {
            bytes[page + 0x300] ^= 0xFF
        }
        try bytes.write(to: executable)
        #expect(UpdateInstaller.verify(good, bundleIdentifier: "com.example.tool", newerThan: current, requirement: ours) == .signatureMismatch)
    }

    @Test func takesTheAppOutOfAnImage() throws {
        let sandbox = try Sandbox()
        let source = try app("Image/Tool.app", version: "1.1.0", in: sandbox)
        let image = sandbox.url("Tool.dmg")
        let create = LaunchControl.run(
            ["create", "-quiet", "-srcfolder", path(source.deletingLastPathComponent()), "-volname", "Tool", "-format", "UDZO", path(image)],
            tool: "/usr/bin/hdiutil"
        )
        try #require(create.status == 0)
        let staging = try sandbox.directory("Staging")
        let copy = try UpdateInstaller.extractApp(fromImage: image, named: "Tool.app", into: staging)
        #expect(version(of: copy) == "1.1.0")
        #expect(LaunchControl.run(["--verify", "--strict", path(copy)], tool: "/usr/bin/codesign").status == 0)
        // The image is closed again: its mount point is empty.
        let mountPoints = try FileManager.default.contentsOfDirectory(atPath: path(staging)).filter { $0.hasPrefix("image-") }
        for mountPoint in mountPoints {
            #expect(try FileManager.default.contentsOfDirectory(atPath: path(staging.appending(path: mountPoint))).isEmpty)
        }
        #expect(throws: UpdateInstaller.Failure.noAppInImage) {
            try UpdateInstaller.extractApp(fromImage: image, named: "Missing.app", into: staging)
        }
    }

    @Test func swapsTheAppInPlace() throws {
        let sandbox = try Sandbox()
        let installed = try app("Applications/Tool.app", version: "1.0.0", in: sandbox)
        let update = try app("Download/Tool.app", version: "1.1.0", in: sandbox)
        let trash = FakeTrash(directory: sandbox.url("Trash"))
        #expect(UpdateInstaller.canReplace(installed))

        try UpdateInstaller.replace(installed, with: update, trash: trash)
        #expect(version(of: installed) == "1.1.0")
        #expect(!sandbox.exists(update))
        #expect(trash.contents.count == 1)
        // Nothing is left behind next to the app.
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(sandbox.url("Applications"))) == ["Tool.app"])
    }

    @Test func knowsWhereItCantReplace() throws {
        let sandbox = try Sandbox()
        let installed = try app("Locked/Tool.app", version: "1.0.0", in: sandbox)
        let folder = sandbox.url("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path(folder))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(folder)) }
        #expect(!UpdateInstaller.canReplace(installed))
        #expect(!UpdateInstaller.canReplace(URL(filePath: "/private/var/folders/xy/AppTranslocation/ABC/d/XCleaner.app")))
    }
}
