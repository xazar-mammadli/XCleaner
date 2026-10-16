import AppKit
import CleanerCore
import SwiftUI

/// A fix for one well-known problem. Each runs one fixed command as an administrator, after macOS asks for the password.
enum MaintenanceTask: String, CaseIterable, Identifiable {
    case flushDNS, reindexSpotlight, thinSnapshots

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .flushDNS: "Flush the DNS Cache"
        case .reindexSpotlight: "Reindex Spotlight"
        case .thinSnapshots: "Thin Local Snapshots"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .flushDNS:
            "Makes your Mac forget the addresses of websites it looked up. Helps when sites don't open after a network or DNS change."
        case .reindexSpotlight:
            "Builds the search index again, for when Spotlight misses files or shows ones that are gone. This takes a while, and your Mac works harder until it's done."
        case .thinSnapshots:
            "Frees the space taken by local Time Machine snapshots, which macOS keeps between backups. Backups on your backup disk stay as they are."
        }
    }

    var systemImage: String {
        switch self {
        case .flushDNS: "network"
        case .reindexSpotlight: "magnifyingglass"
        case .thinSnapshots: "externaldrive.badge.timemachine"
        }
    }

    /// Fixed text: nothing from outside ever goes into these.
    fileprivate var command: String {
        switch self {
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .reindexSpotlight: "/usr/bin/mdutil -E /"
        case .thinSnapshots: "/usr/bin/tmutil thinlocalsnapshots / 999999999999999 4"
        }
    }

    /// Whether it removes anything, so Test Mode holds it back.
    var removesData: Bool { self == .thinSnapshots }

    /// What to explain before macOS asks for the password.
    var confirmation: LocalizedStringResource {
        switch self {
        case .flushDNS:
            "Your Mac looks up website addresses afresh, so sites may take a moment longer to open the first time. Nothing else changes."
        case .reindexSpotlight:
            "Spotlight forgets its index and builds it again. Searches may miss files until it's done, which can take an hour or more."
        case .thinSnapshots:
            "Local snapshots let you restore files between backups. Removing them frees space, but you can no longer go back to those moments."
        }
    }
}

/// Drives Maintenance.
@Observable
final class MaintenanceModel {
    enum Outcome: Equatable {
        case done, cancelled, keptInTestMode
        case failed(String)
    }

    private(set) var running: MaintenanceTask?
    private(set) var outcomes: [MaintenanceTask: Outcome] = [:]
    /// Local Time Machine snapshots on the startup disk, once counted.
    private(set) var snapshotCount: Int?

    func refresh() {
        Task {
            snapshotCount = await Task.detached(priority: .utility) { Self.countSnapshots() }.value
        }
    }

    func run(_ task: MaintenanceTask, method: DeletionMethod) {
        guard running == nil else { return }
        if task.removesData, method == .dryRun {
            outcomes[task] = .keptInTestMode
            return
        }
        running = task
        Task {
            // A moment for the spinner to show before macOS's password prompt takes over.
            try? await Task.sleep(for: .milliseconds(100))
            outcomes[task] = switch Administrator.run(task.command) {
            case .success: .done
            case .failure(.cancelled): .cancelled
            case .failure(.failed(let message)): .failed(message)
            }
            running = nil
            if task == .thinSnapshots { refresh() }
        }
    }

    nonisolated private static func countSnapshots() -> Int? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("com.apple.TimeMachine.") }.count
    }
}
