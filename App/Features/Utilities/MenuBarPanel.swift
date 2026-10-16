import AppKit
import CleanerCore
import SwiftUI

/// Processor, memory, disk, network and battery, measured every two seconds while someone looks.
@Observable
final class SystemMonitor {
    struct Reading {
        var processorLoad: Double?
        var gpu: GPUStatus?
        var memory: MemoryUsage?
        var disk: VolumeUsage?
        /// Bytes per second.
        var download: Double?
        var upload: Double?
        var battery: BatteryStatus?
    }

    private(set) var reading = Reading()

    /// Measures until the task running it is cancelled, which happens when the panel closes.
    func monitor() async {
        var ticks = SystemStats.processorTicks()
        var network = SystemStats.networkCounters()
        var time = ContinuousClock.now
        readSlowChanging()
        // The first numbers come quickly; after that, every two seconds is plenty.
        var interval = Duration.milliseconds(500)
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            interval = .seconds(2)
            let now = ContinuousClock.now
            let elapsed = (now - time).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let newTicks = SystemStats.processorTicks()
            let newNetwork = SystemStats.networkCounters()
            if let newTicks, let ticks { reading.processorLoad = newTicks.load(since: ticks) }
            if seconds > 0 {
                let traffic = newNetwork.bytes(since: network)
                reading.download = Double(traffic.received) / seconds
                reading.upload = Double(traffic.sent) / seconds
            }
            readSlowChanging()
            ticks = newTicks
            network = newNetwork
            time = now
        }
    }

    private func readSlowChanging() {
        reading.gpu = GPUStats.status()
        reading.memory = SystemStats.memory()
        reading.disk = try? VolumeUsage.startupDisk()
        reading.battery = SystemStats.battery()
    }
}

/// What the menu bar item opens. Inside XCleaner's own window it shows as a preview, without the buttons.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var isPreview = false
    @State private var monitor = SystemMonitor()

    var body: some View {
        let reading = monitor.reading
        VStack(alignment: .leading, spacing: 10) {
            if !isPreview {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(verbatim: "XCleaner")
                        .font(.headline)
                    Spacer()
                    Button("Open XCleaner") { showWindow() }
                }
                Divider()
            }
            StatRow(
                systemImage: "cpu", title: "CPU",
                value: reading.processorLoad.map { "\($0.formatted(.percent.precision(.fractionLength(0))))" },
                fraction: reading.processorLoad, tint: (reading.processorLoad ?? 0) > 0.8 ? .orange : .accentColor
            )
            Divider()
            StatRow(
                systemImage: "display", title: "GPU",
                value: reading.gpu.map { "\($0.utilization.formatted(.percent.precision(.fractionLength(0))))" },
                fraction: reading.gpu?.utilization, tint: (reading.gpu?.utilization ?? 0) > 0.8 ? .orange : .accentColor
            )
            Divider()
            StatRow(
                systemImage: "memorychip", title: "Memory",
                value: reading.memory.map { String(localized: "\($0.usedBytes.formattedMemory) of \($0.totalBytes.formattedMemory)") },
                fraction: reading.memory.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) },
                tint: reading.memory?.pressure == .normal || reading.memory == nil ? .accentColor : .orange
            )
            Divider()
            StatRow(
                systemImage: "internaldrive", title: "Disk",
                value: reading.disk.map { String(localized: "\($0.availableBytes.formattedBytes) available") },
                fraction: reading.disk.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) },
                tint: .accentColor
            )
            Divider()
            HStack(spacing: 10) {
                RowIcon(systemImage: "network")
                Text("Network")
                Spacer()
                if let download = reading.download, let upload = reading.upload {
                    Text(verbatim: "↓ \(rate(download))   ↑ \(rate(upload))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "…")
                        .foregroundStyle(.secondary)
                }
            }
            if let battery = reading.battery {
                Divider()
                StatRow(
                    systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent", title: "Battery",
                    value: batteryText(battery), fraction: battery.level, tint: battery.level < 0.2 && !battery.isOnPowerAdapter ? .orange : .green
                )
            }
            if !isPreview {
                Divider()
                HStack {
                    Button("Quick Cleanup") {
                        model.startQuickCleanup()
                        showWindow()
                    }
                    Spacer()
                    Button("Quit XCleaner") { NSApp.terminate(nil) }
                }
            }
        }
        .padding(isPreview ? 0 : 14)
        .frame(width: isPreview ? nil : 320)
        .task { await monitor.monitor() }
    }

    private func showWindow() {
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        String(localized: "\(Int64(bytesPerSecond).formattedBytes)/s")
    }

    private func batteryText(_ battery: BatteryStatus) -> String {
        let level = battery.level.formatted(.percent.precision(.fractionLength(0)))
        if battery.isCharging { return String(localized: "\(level), charging") }
        if battery.isOnPowerAdapter { return String(localized: "\(level), on power adapter") }
        guard let minutes = battery.minutesLeft else { return level }
        let left = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "\(level), \(left) left")
    }
}

private struct StatRow: View {
    let systemImage: String
    let title: LocalizedStringResource
    let value: String?
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                RowIcon(systemImage: systemImage)
                Text(title)
                Spacer()
                Text(verbatim: value ?? "…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(fraction ?? 0, 0), 1))
                .tint(tint)
                .padding(.leading, 30)
        }
    }
}

private struct RowIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(.tint)
            .frame(width: 20)
    }
}
