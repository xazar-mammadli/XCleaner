import Foundation

/// Moves items to the Trash. A protocol so tests can use a stand-in and never touch the real Trash.
public protocol TrashHandling: Sendable {
    /// Returns where the item ended up, when known.
    @discardableResult
    func moveToTrash(_ url: URL) throws -> URL?
}

/// The Finder Trash, where the user can put things back.
public struct SystemTrash: TrashHandling {
    public init() {}

    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
