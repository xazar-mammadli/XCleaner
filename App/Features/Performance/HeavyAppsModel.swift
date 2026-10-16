import AppKit
import CleanerCore
import SwiftUI

enum PerformanceTool: String, CaseIterable, Identifiable {
    case heavyApps, startupItems, maintenance

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .heavyApps: "Heavy Apps"
        case .startupItems: "Startup Items"
        case .maintenance: "Maintenance"
        }
    }
}

/// Drives Heavy Apps: what each app uses of the processor and memory, measured every two seconds while the page is open.
@Observable
final class HeavyAppsModel {
    enum Order: String, CaseIterable, Identifiable {
        case processor, graphics, memory

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .processor: "CPU"
            case .graphics: "GPU"
            case .memory: "Memory"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case apps, allProcesses

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .apps: "Apps"
            case .allProcesses: "All Processes"
            }
        }
    }

    private(set) var groups: [ProcessGroup] = []
    private(set) var memory: MemoryUsage?
    private(set) var processorLoad: Double?
    private(set) var gpu: GPUStatus?
    private(set) var hasSampled = false
    var order = Order.processor
    var scope = Scope.apps
    /// Processes of apps that can be asked to quit: apps in the Dock, menu bar apps that didn't come with macOS,
    /// but never Finder or XCleaner.
    private var quittablePIDs: Set<pid_t> = []

    var visibleGroups: [ProcessGroup] {
        let shown = scope == .apps ? groups.filter { $0.bundlePath != nil } : groups
        switch order {
        case .processor: return shown.sorted { ($0.cpuPercent, $0.footprint) > ($1.cpuPercent, $1.footprint) }
        case .graphics: return shown.sorted { ($0.gpuPercent, $0.cpuPercent) > ($1.gpuPercent, $1.cpuPercent) }
        case .memory: return shown.sorted { $0.footprint > $1.footprint }
        }
    }

    func canQuit(_ group: ProcessGroup) -> Bool {
        group.pids.contains { quittablePIDs.contains($0) }
    }

    /// Asks the app to quit, as the Dock would: it can still ask to save documents. Force quitting skips that.
    func quit(_ group: ProcessGroup, force: Bool) {
        for app in NSWorkspace.shared.runningApplications where group.pids.contains(app.processIdentifier) {
            if force { app.forceTerminate() } else { app.terminate() }
        }
    }

    /// Measures until the task running it is cancelled, which happens when the page goes away.
    func monitor() async {
        var (previous, previousGPUTimes) = await Self.sampleProcesses()
        var previousTicks = SystemStats.processorTicks()
        var previousTime = ContinuousClock.now
        // The first numbers come quickly; after that, every two seconds is plenty.
        var interval = Duration.milliseconds(500)
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            interval = .seconds(2)
            let (current, gpuTimes) = await Self.sampleProcesses()
            let now = ContinuousClock.now
            let ticks = SystemStats.processorTicks()
            groups = ProcessUsage.groups(
                current: current, previous: previous, elapsed: (now - previousTime).nanoseconds,
                gpuTimes: gpuTimes, previousGPUTimes: previousGPUTimes
            )
            if let ticks, let previousTicks { processorLoad = ticks.load(since: previousTicks) }
            memory = SystemStats.memory()
            gpu = GPUStats.status()
            quittablePIDs = Self.quittablePIDs()
            hasSampled = true
            previous = current
            previousGPUTimes = gpuTimes
            previousTicks = ticks
            previousTime = now
        }
    }

    private static func quittablePIDs() -> Set<pid_t> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPID, app.bundleIdentifier != "com.apple.finder" else { return false }
            switch app.activationPolicy {
            case .regular: return true
            // Menu bar helpers of macOS itself, such as Control Center, would only start again.
            case .accessory: return !(app.bundleURL?.path(percentEncoded: false).hasPrefix("/System/") ?? true)
            default: return false
            }
        }
        return Set(apps.map(\.processIdentifier))
    }

    private static func sampleProcesses() async -> ([ProcessSample], [Int32: UInt64]) {
        await Task.detached(priority: .utility) { (ProcessSampler.sample(), GPUStats.timeByProcess()) }.value
    }
}

private extension Duration {
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }
}
