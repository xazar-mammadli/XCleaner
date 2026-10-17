import Foundation

/// Picks the copy worth keeping in each group, so the others can be selected for removal.
///
/// One copy stays on every disk, since copies on another disk are usually backups. On each disk it keeps the copy in a
/// lasting place (Documents, Pictures, Movies or Music before Desktop, and Downloads last), not named like a copy
/// ("Report copy.pdf", "Report (1).pdf"), the oldest, and the one least deep in folders.
public enum SmartSelect {
    /// The copies to keep. `avoiding` marks copies better not kept, such as those inside folders picked for removal;
    /// such a copy is kept only when its disk has no other.
    public static func keepers(
        in group: DuplicateGroup, home: URL, avoiding: (DuplicateItem) -> Bool = { _ in false }
    ) -> Set<URL> {
        let homePath = PathUtilities.realPath(home.path(percentEncoded: false)) ?? home.path(percentEncoded: false)
        var keep = Set<URL>()
        for copies in Dictionary(grouping: group.items, by: \.device).values {
            let preferred = copies.filter { !avoiding($0) }
            let candidates = preferred.isEmpty ? copies : preferred
            if let best = candidates.min(by: { rank($0, in: group, home: homePath) < rank($1, in: group, home: homePath) }) {
                keep.insert(best.url)
            }
        }
        return keep
    }

    /// Of two folders to merge, the one worth keeping: the fuller one, then the one in the better place, then the one
    /// not named like a copy, then the one with the shorter path.
    public static func folderToKeep(_ pair: SimilarFolders, home: URL) -> URL {
        if pair.firstFiles != pair.secondFiles { return pair.firstFiles > pair.secondFiles ? pair.first : pair.second }
        let homePath = PathUtilities.realPath(home.path(percentEncoded: false)) ?? home.path(percentEncoded: false)
        func rank(_ url: URL) -> (Int, Int, Int, String) {
            let path = url.path(percentEncoded: false)
            let copyName = url.lastPathComponent.range(of: copyPattern, options: [.regularExpression, .caseInsensitive]) != nil
            return (place(of: path, home: homePath), copyName ? 1 : 0, path.count, path)
        }
        return rank(pair.first) <= rank(pair.second) ? pair.first : pair.second
    }

    static let copyPattern = #"(^copy of )|([ _-]copy( \d+)?$)|( ?\(\d+\)$)"#

    struct Rank: Comparable {
        let place: Int
        let looksLikeCopy: Bool
        let created: Date
        let depth: Int
        let path: String

        static func < (first: Rank, second: Rank) -> Bool {
            (first.place, first.looksLikeCopy ? 1 : 0, first.created, first.depth, first.path)
                < (second.place, second.looksLikeCopy ? 1 : 0, second.created, second.depth, second.path)
        }
    }

    static func rank(_ item: DuplicateItem, in group: DuplicateGroup, home: String) -> Rank {
        let path = item.url.path(percentEncoded: false)
        return Rank(
            place: place(of: path, home: home), looksLikeCopy: looksLikeCopy(item, in: group),
            created: item.created ?? .distantFuture, depth: path.split(separator: "/").count, path: path
        )
    }

    /// Lower is a better place to keep a file.
    static func place(of path: String, home: String) -> Int {
        guard path.hasPrefix(home + "/") else { return 1 }
        switch path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) {
        case "Documents", "Pictures", "Movies", "Music": return 0
        case "Desktop": return 2
        case "Downloads": return 3
        default: return 1
        }
    }

    /// Named the way Finder, browsers and other apps name copies, in English. "Name 2" counts only when the group
    /// also holds a plain "Name", since many files end in a number anyway.
    static func looksLikeCopy(_ item: DuplicateItem, in group: DuplicateGroup) -> Bool {
        let name = stem(of: item)
        if name.range(of: copyPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        guard let number = name.range(of: #" \d+$"#, options: .regularExpression) else { return false }
        let base = name[..<number.lowerBound]
        return group.items.contains { stem(of: $0).caseInsensitiveCompare(base) == .orderedSame }
    }

    private static func stem(of item: DuplicateItem) -> String {
        item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
    }
}
