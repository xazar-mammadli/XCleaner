import Foundation
import Testing
@testable import CleanerCore

@Suite("SafetyGuard")
struct SafetyGuardTests {
    let sandbox: Sandbox
    let home: URL
    let caches: URL
    let safety: SafetyGuard

    init() throws {
        sandbox = try Sandbox()
        home = try sandbox.directory("home")
        caches = try sandbox.directory("home/Library/Caches")
        safety = SafetyGuard(policy: .forTests(home: home))
    }

    @Test func allowsAnItemInsideItsRoot() throws {
        let folder = try sandbox.directory("home/Library/Caches/com.example.app")
        #expect(safety.evaluate(folder, origin: .rule, root: caches) == .allowed(path: path(folder), trashOnly: false))
    }

    @Test func refusesTheRootItself() throws {
        let root = try sandbox.directory("home/Library/Caches/com.example.app")
        #expect(safety.evaluate(root, origin: .rule, root: root) == .blocked(.outsideAllowedRoot))
    }

    @Test func refusesASiblingThatOnlySharesThePrefix() throws {
        let item = try sandbox.file("home/Library/CachesOld/data")
        #expect(safety.evaluate(item, origin: .rule, root: caches) == .blocked(.outsideAllowedRoot))
    }

    @Test func refusesDotDotEscapes() throws {
        try sandbox.file("home/Library/Keychains/login.keychain-db")
        let sneaky = caches.appending(path: "../Keychains/login.keychain-db")
        #expect(safety.evaluate(sneaky, origin: .rule, root: caches) == .blocked(.protectedLocation(path(home) + "/Library/Keychains")))
    }

    @Test func refusesPathsThatEscapeThroughASymlinkedFolder() throws {
        let secret = try sandbox.file("outside/secret.txt")
        try sandbox.symlink("home/Library/Caches/link", to: secret.deletingLastPathComponent())
        let throughLink = caches.appending(path: "link/secret.txt")
        #expect(safety.evaluate(throughLink, origin: .rule, root: caches) == .blocked(.outsideAllowedRoot))
    }

    @Test func treatsASymlinkAsTheLinkNotItsTarget() throws {
        let secret = try sandbox.file("outside/secret.txt")
        let link = try sandbox.symlink("home/Library/Caches/link", to: secret)
        #expect(safety.evaluate(link, origin: .rule, root: caches) == .allowed(path: path(link), trashOnly: false))
    }

    @Test func keepsRulesOutOfPersonalFolders() throws {
        let report = try sandbox.file("home/Documents/report.pdf")
        #expect(safety.evaluate(report, origin: .rule, root: home) == .blocked(.personalData(path(home) + "/Documents")))
    }

    @Test func letsPickedPersonalFilesGoOnlyToTheTrash() throws {
        let movie = try sandbox.file("home/Movies/holiday.mov")
        #expect(safety.evaluate(movie, origin: .userSelection, root: home) == .allowed(path: path(movie), trashOnly: true))
    }

    @Test func neverTouchesProtectedTreesEvenWhenPicked() throws {
        let note = try sandbox.file("home/Library/Mobile Documents/com~apple~CloudDocs/notes.txt")
        #expect(safety.evaluate(note, origin: .userSelection, root: home)
            == .blocked(.protectedLocation(path(home) + "/Library/Mobile Documents")))
    }

    @Test func neverRemovesProtectedContainers() throws {
        let downloads = try sandbox.directory("home/Downloads")
        #expect(safety.evaluate(downloads, origin: .userSelection, root: home) == .blocked(.protectedContainer(path(downloads))))
    }

    @Test func keepsAppBundlesSealed() throws {
        let applications = try sandbox.directory("home/Applications")
        let infoPlist = try sandbox.file("home/Applications/Example.app/Contents/Info.plist")
        let app = sandbox.url("home/Applications/Example.app")
        #expect(safety.evaluate(infoPlist, origin: .userSelection, root: applications) == .blocked(.insideSealedPackage(path(app))))
        #expect(safety.evaluate(app, origin: .userSelection, root: applications) == .allowed(path: path(app), trashOnly: true))
    }

    @Test func reportsMissingItems() {
        #expect(safety.evaluate(caches.appending(path: "nothing-here"), origin: .rule, root: caches) == .blocked(.doesNotExist))
    }

    @Test func refusesNonFileURLs() throws {
        let web = try #require(URL(string: "https://example.com/cache"))
        #expect(safety.evaluate(web, origin: .rule, root: caches) == .blocked(.notAFileURL))
    }

    @Test func protectsPathsWrittenInAnotherLetterCase() throws {
        try sandbox.file("home/Library/Keychains/login.keychain-db")
        let shouting = URL(filePath: path(home) + "/LIBRARY/keychains/login.keychain-db")
        if case .allowed = safety.evaluate(shouting, origin: .userSelection, root: home) {
            Issue.record("A protected path spelled in another letter case was allowed")
        }
    }

    @Test func honoursTheUsersExclusions() throws {
        let kept = try sandbox.directory("home/Library/Caches/com.example.keep")
        let careful = SafetyGuard(policy: .forTests(home: home, excluding: [kept]))
        #expect(careful.evaluate(kept, origin: .rule, root: caches) == .blocked(.excludedByUser(path(kept))))
        #expect(careful.isExcluded(kept.appending(path: "inner")))
        #expect(!careful.isExcluded(caches.appending(path: "com.example.other")))
    }

    @Test func standardPolicyProtectsSystemAndTemporaryFolders() throws {
        let strict = SafetyGuard(policy: .standard(home: home))

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0)
        let userTemp = URL(filePath: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        #expect(strict.evaluate(userTemp, origin: .userSelection, root: URL(filePath: "/"))
            == .blocked(.protectedLocation("/private/var/folders")))

        let systemFile = URL(filePath: "/System/Library/CoreServices/SystemVersion.plist")
        #expect(strict.evaluate(systemFile, origin: .userSelection, root: URL(filePath: "/"))
            == .blocked(.protectedLocation("/System")))
    }
}
