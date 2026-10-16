import Foundation
import UniformTypeIdentifiers

/// File facts that live outside the normal attributes, in extended attributes macOS maintains.
enum FileMetadata {
    /// The "Date Last Opened" Finder shows.
    static func lastUsedDate(atPath path: String) -> Date? {
        guard let data = extendedAttribute("com.apple.lastuseddate#PS", atPath: path), data.count >= 16 else { return nil }
        let seconds = data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: Int64.self)) }
        let nanoseconds = data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int64.self)) }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    /// Whether macOS marked the file as a screenshot when it saved it. Works in every language, unlike file names.
    static func isScreenCapture(atPath path: String) -> Bool {
        guard let data = extendedAttribute("com.apple.metadata:kMDItemIsScreenCapture", atPath: path),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    static func kind(ofExtension pathExtension: String) -> FileKind {
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension.lowercased()) else { return .other }
        // Disk images also count as archives, so they are checked first.
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .content) { return .document }
        return .other
    }

    private static func extendedAttribute(_ name: String, atPath path: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data.prefix(read) : nil
    }
}
