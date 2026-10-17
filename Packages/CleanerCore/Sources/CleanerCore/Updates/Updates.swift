import Foundation
import Security

/// A version such as "1.2.3", compared number by number.
public struct AppVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let numbers: [Int]

    /// Reads "1.2.3" or "v1.2.3". Anything after the numbers, such as "-beta", is left out.
    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        let core = trimmed.prefix { $0.isNumber || $0 == "." }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (first: AppVersion, second: AppVersion) -> Bool {
        let count = max(first.numbers.count, second.numbers.count)
        for index in 0..<count {
            let left = index < first.numbers.count ? first.numbers[index] : 0
            let right = index < second.numbers.count ? second.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (first: AppVersion, second: AppVersion) -> Bool { !(first < second) && !(second < first) }

    public func hash(into hasher: inout Hasher) {
        var numbers = numbers
        while numbers.last == 0 { numbers.removeLast() }
        hasher.combine(numbers)
    }
}

/// A published release, as GitHub describes the latest one.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: AppVersion
    public let title: String
    /// What changed, in Markdown.
    public let notes: String
    public let pageURL: URL
    /// The disk image to install from, when the release has one.
    public let imageURL: URL?
    public let imageSize: Int64?

    public init(version: AppVersion, title: String, notes: String, pageURL: URL, imageURL: URL?, imageSize: Int64?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.imageURL = imageURL
        self.imageSize = imageSize
    }

    /// Reads GitHub's answer to `GET /repos/{owner}/{repo}/releases/latest`.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int64?
                let browser_download_url: URL
            }

            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name)
        else { return nil }
        let image = release.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
        return ReleaseInfo(
            version: version, title: release.name?.isEmpty == false ? release.name! : release.tag_name, notes: release.body ?? "",
            pageURL: release.html_url, imageURL: image?.browser_download_url, imageSize: image?.size
        )
    }
}

/// Replaces the running copy of XCleaner with a newer release, after checking that the new copy is genuine: a valid
/// signature that the running copy's own designated requirement accepts, which only a release signed with the same
/// certificate meets. Nothing is replaced until that check passes, and the old copy goes to the Trash.
public enum UpdateInstaller {
    public enum Failure: Error, Sendable, Equatable {
        /// The running copy carries no certificate (a local build), so there is nothing to check an update against.
        case notFromRelease
        /// The running copy sits where it can't be replaced: a read-only folder, or a copy macOS runs from a hidden
        /// place after downloading it.
        case notReplaceable
        case downloadFailed
        /// The disk image couldn't be opened, or holds no XCleaner.
        case noAppInImage
        /// The app in the image is another app, or not newer.
        case wrongApp
        /// The app in the image isn't signed, or not by whoever signed the running copy.
        case signatureMismatch
        case installFailed(String)
    }

    /// The running app's designated requirement, when it is signed with a certificate.
    public static func requirementOfRunningApp() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode, hasCertificate(staticCode) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Whether an app at `url` could be replaced: its folder takes changes, and it isn't run from a translocated copy.
    public static func canReplace(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        guard !path.contains("/AppTranslocation/") else { return false }
        return access(url.deletingLastPathComponent().path(percentEncoded: false), W_OK) == 0 && access(path, W_OK) == 0
    }

    /// Checks the app at `candidate` before it may replace the running one.
    public static func verify(
        _ candidate: URL, bundleIdentifier: String, newerThan current: AppVersion, requirement: SecRequirement
    ) -> Failure? {
        guard let info = NSDictionary(contentsOf: candidate.appending(path: "Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), current < version
        else { return .wrongApp }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return .signatureMismatch
        }
        // Every architecture and every resource is checked, and the signer must be the one the running copy names.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else { return .signatureMismatch }
        return nil
    }

    /// Opens the disk image read-only and out of sight, copies the XCleaner inside into `folder`, and closes the image.
    public static func extractApp(fromImage image: URL, named appName: String, into folder: URL) throws -> URL {
        let mountPoint = folder.appending(path: "image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = LaunchControl.run(
            ["attach", image.path(percentEncoded: false), "-nobrowse", "-readonly", "-noautoopen", "-mountpoint",
             mountPoint.path(percentEncoded: false)],
            tool: "/usr/bin/hdiutil"
        )
        guard attach.status == 0 else { throw Failure.noAppInImage }
        defer { _ = LaunchControl.run(["detach", mountPoint.path(percentEncoded: false), "-force"], tool: "/usr/bin/hdiutil") }
        let source = mountPoint.appending(path: appName)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { throw Failure.noAppInImage }
        let copy = folder.appending(path: appName)
        // ditto keeps the code signature, extended attributes and symlinks exactly as they are.
        let ditto = LaunchControl.run([source.path(percentEncoded: false), copy.path(percentEncoded: false)], tool: "/usr/bin/ditto")
        guard ditto.status == 0 else { throw Failure.installFailed(ditto.output) }
        return copy
    }

    /// Puts `newApp` where `current` is. The new copy first moves next to the current one, then the two swap places
    /// in one step, so there is never a moment without an XCleaner there. The old copy then goes to the Trash. If
    /// anything fails, the current copy stays as it was.
    public static func replace(_ current: URL, with newApp: URL, trash: any TrashHandling) throws {
        let staged = current.deletingLastPathComponent().appending(path: ".\(current.lastPathComponent)-update-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: newApp, to: staged)
        } catch {
            throw Failure.installFailed(error.localizedDescription)
        }
        guard renamex_np(staged.path(percentEncoded: false), current.path(percentEncoded: false), UInt32(RENAME_SWAP)) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw Failure.installFailed(message)
        }
        // The staged name now holds the previous version.
        _ = try? trash.moveToTrash(staged)
    }

    private static func hasCertificate(_ code: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any]
        else { return false }
        return (signing[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty == false
    }
}
