import Foundation
import Testing
@testable import CleanerCore

@Suite("Duplicates")
struct DuplicateTests {
    private func scan(_ sandbox: Sandbox, minimumSize: Int64 = 100_000, excluding: [URL] = []) async -> DuplicateScanResult {
        let context = ScanContext(
            home: sandbox.root, safety: SafetyGuard(policy: .forTests(home: sandbox.root, excluding: excluding)), apps: FakeAppCatalog()
        )
        return await DuplicateScanner(folders: [sandbox.root], minimumSize: minimumSize).scan(context)
    }

    private func names(_ group: DuplicateGroup, in sandbox: Sandbox) -> Set<String> {
        Set(group.items.map { relative($0.url, in: sandbox) })
    }

    private func relative(_ url: URL, in sandbox: Sandbox) -> String {
        String(url.path(percentEncoded: false).dropFirst(sandbox.root.path(percentEncoded: false).count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    @Test func findsCopiesAndOnlyCopies() async throws {
        let sandbox = try Sandbox()
        let original = noise(1, count: 200_000)
        try sandbox.file("Documents/a.bin", contents: original)
        try sandbox.file("Downloads/a copy.bin", contents: original)
        // Same size, different content.
        try sandbox.file("Pictures/b.bin", contents: noise(2, count: 200_000))
        // The same first and last bytes, one change in the middle: only the full comparison tells them apart.
        var edited = original
        edited[100_000] ^= 0xFF
        try sandbox.file("Documents/c.bin", contents: edited)
        // Copies, but too small to list.
        try sandbox.file("Documents/small.txt", contents: original.prefix(500))
        try sandbox.file("Desktop/small.txt", contents: original.prefix(500))

        let result = await scan(sandbox)
        #expect(result.fileGroups.count == 1)
        let group = try #require(result.fileGroups.first)
        #expect(names(group, in: sandbox) == ["Documents/a.bin", "Downloads/a copy.bin"])
        #expect(group.length == 200_000)
        #expect(group.items.allSatisfy { !$0.isFolder && $0.fileCount == 1 })
    }

    @Test func leavesOutWhatItShouldSkip() async throws {
        let sandbox = try Sandbox()
        let content = noise(3, count: 150_000)
        for skipped in [
            "Library/Caches/x.bin", ".hidden/x.bin", "Projects/node_modules/pkg/x.bin", "Photos.photoslibrary/x.bin",
            "Documents/.x.bin", "Archive/x.bin", "go/pkg/mod/example.com/lib@v1.0.0/x.bin", "go/pkg/mod/example.com/lib@v1.1.0/x.bin",
            "Projects/app/vendor/lib/x.bin", "Shared/locked/x.bin",
        ] {
            try sandbox.file(skipped, contents: content)
        }
        // A read-only folder, as apps keep some: nothing in it can be moved to the Trash.
        let locked = sandbox.url("Shared/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path(locked))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(locked)) }
        let kept = try sandbox.file("Documents/x.bin", contents: content)
        try sandbox.file("Documents/y.bin", contents: content)
        // A hard link is the same file under another name, not a copy.
        try FileManager.default.linkItem(at: kept, to: sandbox.url("Documents/z.bin"))

        let result = await scan(sandbox, excluding: [sandbox.url("Archive")])
        #expect(result.fileGroups.count == 1)
        let group = try #require(result.fileGroups.first)
        let found = names(group, in: sandbox)
        #expect(found.count == 2)
        #expect(found.contains("Documents/y.bin"))
        #expect(found.isSubset(of: ["Documents/x.bin", "Documents/y.bin", "Documents/z.bin"]))
    }

    @Test func clonesFreeNothing() async throws {
        let sandbox = try Sandbox()
        let original = try sandbox.file("Documents/a.bin", contents: noise(4, count: 1_000_000))
        #expect(clonefile(path(original), path(sandbox.url("Documents/b.bin")), 0) == 0)
        try sandbox.file("Documents/c.bin", contents: noise(4, count: 1_000_000))

        let group = try #require(await scan(sandbox).fileGroups.first)
        let byName = Dictionary(uniqueKeysWithValues: group.items.map { ($0.name, $0) })
        #expect(byName["a.bin"]?.reclaimableSize == 0)
        #expect(byName["b.bin"]?.reclaimableSize == 0)
        #expect((byName["c.bin"]?.reclaimableSize ?? 0) >= 1_000_000)
        #expect(byName["b.bin"]?.size ?? 0 >= 1_000_000)
    }

    @Test func findsCopiedFoldersOnce() async throws {
        let sandbox = try Sandbox()
        for folder in ["Pictures/Trip", "Desktop/Trip copy", "Documents/Trip edited"] {
            try sandbox.file("\(folder)/1.jpg", contents: noise(10, count: 400_000))
            try sandbox.file("\(folder)/2.jpg", contents: noise(11, count: 400_000))
            try sandbox.file("\(folder)/notes.txt", contents: Data("Day one".utf8))
            try sandbox.file("\(folder)/Day 2/3.jpg", contents: noise(folder.hasSuffix("edited") ? 99 : 12, count: 400_000))
        }
        // Finder's view settings differ between copies and don't count.
        try sandbox.file("Desktop/Trip copy/.DS_Store", contents: noise(13, count: 600))

        let result = await scan(sandbox)
        #expect(result.folderGroups.count == 1)
        let group = try #require(result.folderGroups.first)
        #expect(group.isFolders)
        #expect(names(group, in: sandbox) == ["Pictures/Trip", "Desktop/Trip copy"])
        #expect(group.items.allSatisfy { $0.fileCount == 4 })
        // Their files aren't listed again, except where a copy is outside them.
        for fileGroup in result.fileGroups {
            #expect(names(fileGroup, in: sandbox).contains { $0.hasPrefix("Documents/Trip edited/") })
        }
    }

    @Test func neverOffersProtectedFolders() async throws {
        let sandbox = try Sandbox()
        // Documents and Downloads hold the same, but are personal folders that never go.
        let content = noise(80, count: 1_200_000)
        try sandbox.file("Documents/a.bin", contents: content)
        try sandbox.file("Downloads/a.bin", contents: content)
        // Nor is anything inside a protected location offered.
        try sandbox.file("Library/Mail/V10/a.bin", contents: content)
        let context = ScanContext(home: sandbox.root, safety: SafetyGuard(policy: .forTests(home: sandbox.root)), apps: FakeAppCatalog())
        let result = await DuplicateScanner(folders: [sandbox.root, sandbox.url("Library/Mail")], minimumSize: 100_000).scan(context)
        #expect(result.folderGroups.isEmpty)
        let group = try #require(result.fileGroups.first)
        #expect(result.fileGroups.count == 1)
        #expect(names(group, in: sandbox) == ["Documents/a.bin", "Downloads/a.bin"])
    }

    @Test func findsSimilarFolders() async throws {
        let sandbox = try Sandbox()
        for (index, name) in ["1.jpg", "2.jpg", "3.jpg", "4.jpg"].enumerated() {
            let content = noise(UInt64(20 + index), count: 120_000)
            try sandbox.file("Pictures/Holiday/\(name)", contents: content)
            try sandbox.file("Downloads/Holiday/\(name)", contents: content)
        }
        try sandbox.file("Pictures/Holiday/5.jpg", contents: noise(30, count: 120_000))
        try sandbox.file("Downloads/Holiday/6.jpg", contents: noise(31, count: 120_000))

        let result = await scan(sandbox)
        #expect(result.folderGroups.isEmpty)
        #expect(result.fileGroups.count == 4)
        let pair = try #require(result.similarFolders.first)
        #expect(result.similarFolders.count == 1)
        #expect(Set([relative(pair.first, in: sandbox), relative(pair.second, in: sandbox)]) == ["Pictures/Holiday", "Downloads/Holiday"])
        #expect(pair.sharedFiles == 4)
        #expect(pair.firstFiles == 5 && pair.secondFiles == 5)
        // The one in Pictures stays rather than the one in Downloads.
        #expect(relative(SmartSelect.folderToKeep(pair, home: sandbox.root), in: sandbox) == "Pictures/Holiday")
    }

    @Test func smartSelectKeepsTheOriginal() async throws {
        let sandbox = try Sandbox()
        let report = noise(40, count: 150_000)
        try sandbox.file("Downloads/report.pdf", contents: report)
        try sandbox.file("Documents/report copy.pdf", contents: report)
        try sandbox.file("Documents/report.pdf", contents: report)
        let photo = noise(41, count: 150_000)
        try sandbox.file("Desktop/photo 2.jpg", contents: photo)
        try sandbox.file("Desktop/photo.jpg", contents: photo)

        let groups = await scan(sandbox).fileGroups
        let reports = try #require(groups.first { $0.items.contains { $0.name == "report.pdf" } })
        let keep = SmartSelect.keepers(in: reports, home: sandbox.root)
        #expect(keep.map { relative($0, in: sandbox) } == ["Documents/report.pdf"])
        // Kept elsewhere when that copy should go anyway.
        let avoiding = SmartSelect.keepers(in: reports, home: sandbox.root) { relative($0.url, in: sandbox) == "Documents/report.pdf" }
        #expect(avoiding.map { relative($0, in: sandbox) } == ["Documents/report copy.pdf"])

        #expect(reports.name == "report.pdf")
        let photos = try #require(groups.first { $0.items.contains { $0.name == "photo.jpg" } })
        #expect(SmartSelect.keepers(in: photos, home: sandbox.root).map { relative($0, in: sandbox) } == ["Desktop/photo.jpg"])
    }

    @Test func removalAlwaysLeavesACopy() async throws {
        let sandbox = try Sandbox()
        let content = noise(50, count: 150_000)
        let a = try sandbox.file("Documents/a.bin", contents: content)
        let b = try sandbox.file("Downloads/b.bin", contents: content)
        let changed = try sandbox.file("Downloads/c.bin", contents: content)
        let groups = await scan(sandbox).fileGroups

        let everything = DuplicateRemoval.plan(removing: [a, b, changed], in: groups)
        #expect(everything.items.isEmpty)
        #expect(everything.skipped.count == 3)
        #expect(everything.skipped.allSatisfy { $0.reason == .lastCopy })

        #expect(DuplicateRemoval.plan(removing: [b], in: groups).items.map(\.url) == [b])

        // Changed since the scan: maybe not a copy anymore.
        try (noise(51, count: 10) + content).write(to: changed)
        let plan = DuplicateRemoval.plan(removing: [b, changed], in: groups)
        #expect(plan.items.map(\.url) == [b])
        #expect(plan.skipped.map(\.reason) == [.changed])
        let removable = try #require(plan.items.first)
        #expect(removable.origin == .userSelection && removable.category == .duplicates)
    }

    @Test func removalChecksFilesAndFoldersTogether() async throws {
        let sandbox = try Sandbox()
        for folder in ["Pictures/Trip", "Desktop/Trip copy"] {
            try sandbox.file("\(folder)/1.jpg", contents: noise(60, count: 600_000))
            try sandbox.file("\(folder)/2.jpg", contents: noise(61, count: 600_000))
        }
        let loose = try sandbox.file("Documents/1.jpg", contents: noise(60, count: 600_000))
        let result = await scan(sandbox)
        let groups = result.fileGroups + result.folderGroups
        let trip = sandbox.url("Pictures/Trip")
        let tripCopy = sandbox.url("Desktop/Trip copy")
        #expect(result.folderGroups.count == 1)
        #expect(result.fileGroups.count == 1)

        // The copy folder goes; the two other copies of 1.jpg can't both go with it.
        let plan = DuplicateRemoval.plan(removing: [tripCopy, loose, sandbox.url("Pictures/Trip/1.jpg")], in: groups)
        #expect(plan.items.map { relative($0.url, in: sandbox) } == ["Desktop/Trip copy"])
        #expect(Set(plan.skipped.map { relative($0.item.url, in: sandbox) }) == ["Documents/1.jpg", "Pictures/Trip/1.jpg"])

        // A picked file inside a picked folder goes with the folder.
        let nested = DuplicateRemoval.plan(removing: [tripCopy, sandbox.url("Desktop/Trip copy/1.jpg")], in: groups)
        #expect(nested.items.map(\.url) == [tripCopy])

        // Both folders can't go.
        #expect(DuplicateRemoval.plan(removing: [trip, tripCopy], in: groups).items.isEmpty)
    }

    @Test func mergeKeepsEveryFile() async throws {
        let sandbox = try Sandbox()
        let keep = try sandbox.directory("Pictures/Holiday")
        let other = try sandbox.directory("Downloads/Holiday")
        try sandbox.file("Pictures/Holiday/1.jpg", contents: noise(70, count: 50_000))
        try sandbox.file("Pictures/Holiday/2.jpg", contents: noise(71, count: 50_000))
        try sandbox.file("Pictures/Holiday/sub/3.jpg", contents: noise(72, count: 50_000))
        try sandbox.file("Downloads/Holiday/1.jpg", contents: noise(70, count: 50_000))
        try sandbox.file("Downloads/Holiday/2.jpg", contents: noise(73, count: 50_000))
        try sandbox.file("Downloads/Holiday/sub/3.jpg", contents: noise(72, count: 50_000))
        try sandbox.file("Downloads/Holiday/sub/4.jpg", contents: noise(74, count: 50_000))
        try sandbox.file("Downloads/Holiday/5.jpg", contents: noise(70, count: 50_000))
        try sandbox.file("Downloads/Holiday/.DS_Store", contents: noise(75, count: 100))

        let safety = SafetyGuard(policy: .forTests(home: sandbox.root))
        let plan = try FolderMerger.plan(keep: keep, other: other, safety: safety).get()
        #expect(Set(plan.duplicates.map { relative($0.file.url, in: sandbox) })
            == ["Downloads/Holiday/1.jpg", "Downloads/Holiday/sub/3.jpg", "Downloads/Holiday/5.jpg"])
        #expect(Set(plan.moves.map { relative($0.destination, in: sandbox) }) == ["Pictures/Holiday/2 2.jpg", "Pictures/Holiday/sub/4.jpg"])

        let trash = FakeTrash(directory: sandbox.url("Trash"))
        let log = AuditLog(directory: sandbox.url("Logs"))
        let cleaner = Cleaner(safety: safety, trash: trash, auditLog: log)

        // A test run changes nothing.
        let dryRun = await FolderMerger.merge(plan, cleaner: cleaner, method: .dryRun)
        #expect(dryRun.moved.count == 2)
        #expect(sandbox.exists(other))
        #expect(trash.contents.isEmpty)

        let report = await FolderMerger.merge(plan, cleaner: cleaner, method: .moveToTrash)
        #expect(report.failures.isEmpty)
        #expect(report.moved.count == 2)
        #expect(report.duplicates.removed.count == 3)
        #expect(report.folder?.removed.count == 1)
        #expect(!sandbox.exists(other))
        #expect(trash.contents.count == 4)
        #expect(try Data(contentsOf: sandbox.url("Pictures/Holiday/2 2.jpg")) == noise(73, count: 50_000))
        #expect(try Data(contentsOf: sandbox.url("Pictures/Holiday/2.jpg")) == noise(71, count: 50_000))
        #expect(try Data(contentsOf: sandbox.url("Pictures/Holiday/sub/4.jpg")) == noise(74, count: 50_000))
        let moved = await log.allEntries().filter { $0.action == .moved }
        #expect(moved.count == 2)
        #expect(moved.contains { $0.detail?.hasSuffix("Pictures/Holiday/2 2.jpg") == true })
    }

    @Test func mergeRefusesWhatItCantDoSafely() throws {
        let sandbox = try Sandbox()
        let safety = SafetyGuard(policy: .forTests(home: sandbox.root))
        let keep = try sandbox.directory("Pictures/Holiday")
        try sandbox.file("Pictures/Holiday/sub/1.jpg")

        #expect(FolderMerger.plan(keep: keep, other: sandbox.url("Pictures/Holiday/sub"), safety: safety) == .failure(.nested))
        #expect(FolderMerger.plan(keep: keep, other: keep, safety: safety) == .failure(.nested))

        try sandbox.file("Downloads/Linked/1.jpg")
        try sandbox.symlink("Downloads/Linked/link", to: sandbox.url("Documents"))
        guard case .failure(.unsupportedItem) = FolderMerger.plan(keep: keep, other: sandbox.url("Downloads/Linked"), safety: safety) else {
            Issue.record("A folder with a link was merged")
            return
        }
        try sandbox.file("Downloads/Project/.git/HEAD")
        guard case .failure(.unsupportedItem) = FolderMerger.plan(keep: keep, other: sandbox.url("Downloads/Project"), safety: safety) else {
            Issue.record("A folder with a hidden folder was merged")
            return
        }
        // Files can't be moved out of a read-only folder.
        let locked = try sandbox.directory("Downloads/Locked")
        try sandbox.file("Downloads/Locked/1.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path(locked))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(locked)) }
        guard case .failure(.readOnly) = FolderMerger.plan(keep: keep, other: locked, safety: safety) else {
            Issue.record("A read-only folder was merged")
            return
        }
        // Downloads itself can't go once emptied, and nothing moves into Mail.
        #expect(FolderMerger.plan(keep: keep, other: sandbox.url("Downloads"), safety: safety) == .failure(.protectedLocation))
        let mail = try sandbox.directory("Library/Mail/V10")
        #expect(FolderMerger.plan(keep: mail, other: sandbox.url("Downloads/Linked"), safety: safety) == .failure(.protectedLocation))
    }

    @Test func placesNeverReplaceAnything() throws {
        let sandbox = try Sandbox()
        try sandbox.file("Target/x")
        try sandbox.file("Target/a.txt")
        try sandbox.directory("Target/folder")
        var places = Places(root: path(sandbox.url("Target")))
        // "x" is a file, so the folder "x" becomes "x 2".
        #expect(places.destination(for: "x/y.txt").hasSuffix("/Target/x 2/y.txt"))
        #expect(places.destination(for: "x/z.txt").hasSuffix("/Target/x 2/z.txt"))
        #expect(places.destination(for: "a.txt").hasSuffix("/Target/a 2.txt"))
        #expect(places.destination(for: "b.txt").hasSuffix("/Target/b.txt"))
        #expect(places.destination(for: "b.txt").hasSuffix("/Target/b 2.txt"))
        // An existing folder takes more files.
        #expect(places.destination(for: "folder/c.txt").hasSuffix("/Target/folder/c.txt"))

        let source = try sandbox.file("Source/a.txt", contents: Data("new".utf8))
        let moved = try FolderMerger.moveWithoutReplacing(path(source), to: path(sandbox.url("Target/a.txt")))
        #expect(moved.hasSuffix("/Target/a 2.txt"))
        #expect(try String(contentsOf: sandbox.url("Target/a.txt"), encoding: .utf8) != "new")
    }
}

extension FolderMerger.Plan: Equatable {
    public static func == (first: Self, second: Self) -> Bool { first.keep == second.keep && first.other == second.other }
}
