import Foundation

enum PathUtilities {
    /// The canonical form of an existing path, with symlinks, `.` and `..` resolved (`/tmp` becomes `/private/tmp`).
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The canonical path of an item without following the item itself. Only its parent folder is resolved,
    /// so a symlink stays a symlink and removing it can never reach the file it points to.
    static func canonicalItemPath(of url: URL) -> String? {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        guard let parent = realPath(standardized.deletingLastPathComponent().path(percentEncoded: false)) else {
            return nil
        }
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Whether `path` is `ancestor` itself or lies inside it, comparing whole components so that
    /// `/Library/CachesOld` is never mistaken for something inside `/Library/Caches`.
    static func isWithin(_ path: [String], _ ancestor: [String], ignoringCase: Bool) -> Bool {
        guard path.count >= ancestor.count else { return false }
        return zip(path, ancestor).allSatisfy { ignoringCase ? $0.lowercased() == $1.lowercased() : $0 == $1 }
    }

    static func joined(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }
}
