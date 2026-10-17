import Foundation
import Security

/// Who made a program, as far as its code signature tells on this Mac, without going online.
public enum CodeOrigin: Sendable, Hashable {
    /// Part of macOS, or an app from Apple.
    case apple
    case appStore
    /// Signed with a Developer ID, which Apple gives only to developers it knows. Holds the developer's name.
    case identifiedDeveloper(String)
    /// Signed, but not by a developer Apple knows: signed only for this Mac, or with a certificate of its own.
    case unidentifiedDeveloper
    case unsigned
    /// Signed, then changed: the signature no longer matches the program.
    case modified
    /// The program isn't there.
    case missing
    /// The program can't be read, as some helpers only root may read are kept. Nothing is known about it either way.
    case unreadable
}

/// A program that starts on its own, and what stands out about it.
public struct BackgroundReview: Sendable, Hashable {
    public enum Concern: Sendable, Hashable {
        case programMissing
        case unsigned
        case modified
        case unidentifiedDeveloper
        /// The program sits in a hidden folder, or is hidden itself.
        case hiddenLocation
        /// The program sits where every app may write, such as /tmp or /Users/Shared.
        case sharedLocation
        /// It hands a command line to a shell or a script interpreter. Holds the command.
        case runsCommand(String)
    }

    public let program: String?
    public let origin: CodeOrigin
    public let concerns: [Concern]

    public var isWorthALook: Bool { !concerns.isEmpty }
}

/// Looks at the programs that start on their own: who signed them, where they live and how they are started. It flags
/// what is unusual, without calling anything harmful: most items worth a look are simply old or homemade.
public enum BackgroundCheck {
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "osascript", "python", "python3", "perl", "ruby", "php", "node",
    ]
    static let sharedFolders = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]

    public static func review(_ item: LaunchItem) -> BackgroundReview {
        guard item.problem != .empty else { return BackgroundReview(program: item.program, origin: .missing, concerns: [.programMissing]) }
        let program = item.program.map(resolved)
        return review(program: program, arguments: item.arguments)
    }

    public static func review(_ item: LoginItem) -> BackgroundReview {
        review(program: item.url.path(percentEncoded: false), arguments: [])
    }

    static func review(program: String?, arguments: [String]) -> BackgroundReview {
        guard let program else { return BackgroundReview(program: nil, origin: .missing, concerns: [.programMissing]) }
        let origin = origin(ofProgramAt: program)
        var concerns: [BackgroundReview.Concern] = []
        switch origin {
        case .missing: concerns.append(.programMissing)
        case .unsigned: concerns.append(.unsigned)
        case .modified: concerns.append(.modified)
        case .unidentifiedDeveloper: concerns.append(.unidentifiedDeveloper)
        case .apple, .appStore, .identifiedDeveloper, .unreadable: break
        }
        if program.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { concerns.append(.hiddenLocation) }
        if sharedFolders.contains(where: program.hasPrefix) { concerns.append(.sharedLocation) }
        if interpreters.contains((program as NSString).lastPathComponent),
           let flag = arguments.dropFirst().firstIndex(where: { $0 == "-c" || $0 == "-e" }), flag + 1 < arguments.count {
            concerns.append(.runsCommand(arguments[(flag + 1)...].joined(separator: " ")))
        }
        return BackgroundReview(program: program, origin: origin, concerns: concerns)
    }

    /// launchd looks a bare program name up in its standard folders.
    static func resolved(_ program: String) -> String {
        guard !program.hasPrefix("/") else { return program }
        for folder in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where FileManager.default.fileExists(atPath: folder + "/" + program) {
            return folder + "/" + program
        }
        return program
    }

    public static func origin(ofProgramAt path: String) -> CodeOrigin {
        var info = stat()
        guard path.hasPrefix("/"), stat(path, &info) == 0 else { return .missing }
        guard access(path, R_OK) == 0 else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unreadable
        }
        // The program itself is checked; the resources of an app around it would take long and say little here.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        switch SecStaticCodeCheckValidity(code, flags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return .unsigned
        case errSecCSSignatureFailed, errSecCSSignatureInvalid: return .modified
        default: return .unreadable
        }
        if satisfies(code, "anchor apple") { return .apple }
        if satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists") { return .appStore }
        if satisfies(code, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists") {
            return .identifiedDeveloper(developer(of: code) ?? "")
        }
        return .unidentifiedDeveloper
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    /// "Developer ID Application: Example Inc (AB12CD34EF)" gives "Example Inc"; failing that, the team identifier.
    private static func developer(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any]
        else { return nil }
        if let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            var name = Substring(summary)
            if let colon = name.range(of: ": ") { name = name[colon.upperBound...] }
            if let team = name.range(of: " (", options: .backwards) { name = name[..<team.lowerBound] }
            if !name.isEmpty { return String(name) }
        }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
