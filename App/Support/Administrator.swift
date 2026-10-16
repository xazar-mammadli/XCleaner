import AppKit
import CleanerCore
import Foundation

/// Work that needs root, done for one go after macOS asks for the user's password in its own prompt.
/// Nothing keeps running with those rights afterwards.
enum Administrator {
    enum Failure: Error, Equatable {
        /// The user pressed Cancel in the password prompt.
        case cancelled
        case failed(String)
    }

    /// Runs a fixed shell command as root. AppleScript shows the prompt and wants the main thread, which waits meanwhile.
    static func run(_ command: String) -> Result<String, Failure> {
        // The command goes into an AppleScript string literal.
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let result = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges without altering line endings")?
            .executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -128 { return .failure(.cancelled) }
            return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? ""))
        }
        return .success(result?.stringValue ?? "")
    }

    /// Hands `request` to XCleaner's own executable, started as root (see `Launcher`).
    static func perform(_ request: PrivilegedRequest) -> Result<PrivilegedResponse, Failure> {
        guard let executable = Bundle.main.executablePath, let data = try? JSONEncoder().encode(request) else {
            return .failure(.failed(""))
        }
        // Base64 needs no quoting; the path gets single quotes.
        let path = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch run("\(path) --privileged \(data.base64EncodedString())") {
        case .success(let output):
            guard let response = try? JSONDecoder().decode(PrivilegedResponse.self, from: Data(output.utf8)) else {
                return .failure(.failed(output))
            }
            return .success(response)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Removes `items`: those in the system folders in a root run after the password prompt, the rest as usual.
    /// A test run removes nothing, so it needs no password and everything goes the usual way.
    static func clean(
        _ items: [CleanableItem], with cleaner: Cleaner, method: DeletionMethod,
        progress: (@Sendable (CleaningProgress) -> Void)? = nil
    ) async -> CleaningReport {
        let system = method == .dryRun ? [] : items.filter(\.needsAdministrator)
        var report = CleaningReport(requestedMethod: method)
        // One root run per way of removing: what the user picked only ever goes to the Trash.
        let byMethod = Dictionary(grouping: system) { Cleaner.plannedMethod(for: $0, requested: method) }
        for (planned, group) in byMethod.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            report.append(await remove(group, method: planned, log: cleaner.auditLog))
        }
        report.append(await cleaner.clean(items.filter { !system.contains($0) }, method: method, progress: progress))
        return report
    }

    /// Removes items from the system folders as root, and records what happened in the history.
    static func remove(_ items: [CleanableItem], method: DeletionMethod, log: AuditLog?) async -> CleaningReport {
        let request = PrivilegedRequest.remove(paths: items.map { $0.url.path(percentEncoded: false) }, method: method, owner: .current)
        switch perform(request) {
        case .success(let response) where response.succeeded:
            if let log { await response.record(in: log) }
            return response.report(for: items, requestedMethod: method)
        case .success(let response):
            return PrivilegedResponse.failure(for: items, message: response.message ?? "").report(for: items, requestedMethod: method)
        case .failure(.cancelled):
            return PrivilegedResponse.failure(for: items, message: String(localized: "The password prompt was cancelled."))
                .report(for: items, requestedMethod: method)
        case .failure(.failed(let message)):
            return PrivilegedResponse.failure(for: items, message: message).report(for: items, requestedMethod: method)
        }
    }
}

/// XCleaner's real entry point. Started with `--privileged <request>`, it is the root run `Administrator.perform`
/// asked for: it does that one job, prints the outcome as JSON and exits, without ever opening a window.
@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--privileged" {
            exit(runPrivileged(encodedRequest: arguments[2]))
        }
        XCleanerApp.main()
    }

    private static func runPrivileged(encodedRequest: String) -> Int32 {
        guard getuid() == 0 else { return 1 }
        guard let data = Data(base64Encoded: encodedRequest),
              let request = try? JSONDecoder().decode(PrivilegedRequest.self, from: data)
        else { return 2 }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.response = await PrivilegedRunner.perform(request)
            done.signal()
        }
        done.wait()
        FileHandle.standardOutput.write((try? JSONEncoder().encode(outcome.response)) ?? Data())
        return 0
    }

    /// Carries the response out of the task; the semaphore orders the write before the read.
    nonisolated private final class Outcome: @unchecked Sendable {
        var response = PrivilegedResponse(succeeded: false)
    }
}
