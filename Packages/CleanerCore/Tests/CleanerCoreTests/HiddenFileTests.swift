import Foundation
import Testing
@testable import CleanerCore

@Suite("Hidden files")
struct HiddenFileTests {
    private func scanner(_ sandbox: Sandbox, folder: URL? = nil) -> HiddenFileScanner {
        HiddenFileScanner(folder: folder ?? sandbox.root, home: sandbox.root, safety: SafetyGuard(policy: .forTests(home: sandbox.root)))
    }

    private func isFlagged(_ url: URL) -> Bool {
        var info = stat()
        return lstat(path(url), &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    @Test func listsHiddenItemsAtTheTop() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".npm/_cacache/content/a", bytes: 40_000)
        try sandbox.file(".zshrc", bytes: 100)
        try sandbox.file(".ssh/id_ed25519", bytes: 400)
        try sandbox.file(".config/gh/hosts.yml", bytes: 100)
        try sandbox.file(".Trash/old.txt")
        try sandbox.file(".DS_Store")
        try sandbox.file("Documents/visible.txt")
        let library = try sandbox.directory("Library")
        try sandbox.file("Library/Preferences/x.plist")
        try HiddenFlag.setHidden(true, at: library, safety: SafetyGuard(policy: .forTests(home: sandbox.root)))

        let items = scanner(sandbox).topLevel()
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == [".npm", ".zshrc", ".ssh", ".config", "Library"])
        #expect(items.first?.name == ".npm")
        #expect(byName[".npm"]?.role == .other)
        #expect(byName[".npm"]?.canRemove == true)
        #expect((byName[".npm"]?.size ?? 0) >= 40_000)
        #expect(byName[".ssh"]?.role == .credentials)
        // It holds a token, so it is kept like one.
        #expect(byName[".config"]?.role == .credentials)
        #expect(byName["Library"]?.role == .system)
        #expect(byName["Library"]?.size == nil)
        #expect(byName["Library"]?.isHiddenByFlag == true)
    }

    @Test func searchesByNameBelowTheFolder() throws {
        let sandbox = try Sandbox()
        try sandbox.file("Projects/app/.env")
        try sandbox.file("Projects/app/node_modules/pkg/.env")
        try sandbox.file("Projects/app/.git/config")
        try sandbox.file(".config/tool/config.json")
        try sandbox.file(".ssh/config")
        try sandbox.file("Documents/config.txt")
        try sandbox.file("Library/Preferences/.config-cache")

        let finder = scanner(sandbox)
        #expect(finder.search("ENV").map { $0.url.lastPathComponent } == [".env"])
        let root = path(sandbox.root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let found = Set(finder.search("config").map {
            String(path($0.url).trimmingCharacters(in: CharacterSet(charactersIn: "/")).dropFirst(root.count + 1))
        })
        #expect(found == [".config", ".config/tool/config.json", ".ssh/config"])
        #expect(finder.search("config").first { $0.name == "config" }?.role == .credentials)
        #expect(finder.search("   ").isEmpty)
        #expect(finder.search("config", limit: 1).count == 1)
    }

    @Test func hidesAndShowsWithFindersFlag() throws {
        let sandbox = try Sandbox()
        let safety = SafetyGuard(policy: .forTests(home: sandbox.root))
        let file = try sandbox.file("Documents/notes.txt")
        try HiddenFlag.setHidden(true, at: file, safety: safety)
        #expect(isFlagged(file))
        try HiddenFlag.setHidden(false, at: file, safety: safety)
        #expect(!isFlagged(file))
        // Keys stay as they are.
        let key = try sandbox.file(".ssh/id_ed25519")
        #expect(throws: POSIXError.self) { try HiddenFlag.setHidden(true, at: key, safety: safety) }
        #expect(!isFlagged(key))
    }

    @Test func neverRemovesWhatHoldsKeys() throws {
        let sandbox = try Sandbox()
        let safety = SafetyGuard(policy: .forTests(home: sandbox.root))
        let docker = try sandbox.directory(".docker")
        try sandbox.file(".docker/config.json")
        try sandbox.file(".ssh/id_ed25519")
        let npm = try sandbox.directory(".npm")
        try sandbox.file(".npm/_logs/debug.log")
        guard case .blocked(.protectedLocation) = safety.evaluate(docker, origin: .userSelection, root: sandbox.root) else {
            Issue.record("A folder holding credentials could be removed")
            return
        }
        guard case .blocked(.protectedLocation) = safety.evaluate(sandbox.url(".ssh"), origin: .userSelection, root: sandbox.root) else {
            Issue.record("The SSH folder could be removed")
            return
        }
        let verdict = safety.evaluate(npm, origin: .userSelection, root: sandbox.root)
        guard case .allowed = verdict else {
            Issue.record("A plain hidden cache couldn't be removed: \(verdict)")
            return
        }
    }
}
