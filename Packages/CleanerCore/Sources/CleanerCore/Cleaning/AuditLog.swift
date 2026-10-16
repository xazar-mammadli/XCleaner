import Foundation

/// An append-only record of everything XCleaner removed, or refused to remove: one JSON line per action,
/// one file per day. It backs the cleanup history, so the user can always see exactly what happened.
public actor AuditLog {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable {
            case movedToTrash, deleted, dryRun, blocked, failed
        }

        public let date: Date
        public let action: Action
        public let path: String
        public let bytes: Int64
        public let detail: String?

        public init(date: Date = .now, action: Action, path: String, bytes: Int64, detail: String? = nil) {
            self.date = date
            self.action = action
            self.path = path
            self.bytes = bytes
            self.detail = detail
        }
    }

    /// `~/Library/Logs/XCleaner`
    public static var standardDirectory: URL {
        URL.libraryDirectory.appending(path: "Logs/XCleaner", directoryHint: .isDirectory)
    }

    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dayFormatter: DateFormatter

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    public func record(_ entry: Entry) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = fileURL(for: entry.date)
            var line = try encoder.encode(entry)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file, options: .atomic)
            }
        } catch {
            // The history must never stand in the way of a cleanup, so a failed write is dropped.
        }
    }

    public func entries(on day: Date) -> [Entry] {
        entries(in: fileURL(for: day))
    }

    /// Every recorded action, newest first.
    public func allEntries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("cleanup-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .flatMap { entries(in: $0).reversed() }
    }

    private func entries(in file: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    private func fileURL(for date: Date) -> URL {
        directory.appending(path: "cleanup-\(dayFormatter.string(from: date)).jsonl")
    }
}

extension AuditLog.Entry.Action {
    init(_ method: DeletionMethod) {
        switch method {
        case .moveToTrash: self = .movedToTrash
        case .deletePermanently: self = .deleted
        case .dryRun: self = .dryRun
        }
    }
}
