import AppKit
import CleanerCore
import SwiftUI

struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.performanceTool {
            case .heavyApps: HeavyAppsView()
            case .startupItems: StartupItemsView()
            case .maintenance: MaintenanceView()
            }
        }
        .navigationTitle(Text(SidebarItem.performance.title))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $model.performanceTool) {
                    ForEach(PerformanceTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                } label: {
                    Text(SidebarItem.performance.title)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Heavy apps

private struct HeavyAppsView: View {
    @Environment(AppModel.self) private var model
    @State private var forceQuitting: ProcessGroup?

    var body: some View {
        @Bindable var heavy = model.heavyApps
        let rows = heavy.visibleGroups
        // Only the list scrolls; see HistoryView for why the geometry reader sits at the root.
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Heavy Apps", subtitle: "Apps that use the most memory, CPU and GPU, updated every two seconds.")
                HStack(alignment: .top, spacing: 16) {
                    MemoryCard(memory: heavy.memory)
                    ProcessorCard(load: heavy.processorLoad, gpu: heavy.gpu)
                        .frame(width: 280)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Picker("Show", selection: $heavy.scope) {
                        ForEach(HeavyAppsModel.Scope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .fixedSize()
                    Picker("Sort by", selection: $heavy.order) {
                        ForEach(HeavyAppsModel.Order.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    // Column titles over the rows' numbers: the same widths and spacing as HeavyAppRow.
                    HStack(spacing: 12) {
                        Text("CPU")
                            .frame(width: 70, alignment: .trailing)
                        Text("GPU")
                            .frame(width: 56, alignment: .trailing)
                        Text("Memory")
                            .frame(width: 90, alignment: .trailing)
                        Color.clear
                            .frame(width: 64, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
                }
                if heavy.hasSampled {
                    RowsCard(rows, scrolls: true) { group in
                        HeavyAppRow(group: group, canQuit: heavy.canQuit(group)) { force in
                            if force { forceQuitting = group } else { heavy.quit(group, force: false) }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task { await heavy.monitor() }
        .confirmationDialog(
            Text("Force quit “\(forceQuitting?.name ?? "")”?"),
            isPresented: Binding(get: { forceQuitting != nil }, set: { if !$0 { forceQuitting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let group = forceQuitting { heavy.quit(group, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app closes right away, and changes it hasn't saved are lost.")
        }
    }
}

private struct MemoryCard: View {
    let memory: MemoryUsage?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "memorychip")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory")
                            .font(.headline)
                        if let memory {
                            Text("\(memory.usedBytes.formattedMemory) used of \(memory.totalBytes.formattedMemory)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                    if let memory {
                        PressureBadge(pressure: memory.pressure)
                    }
                }
                if let memory {
                    let free = memory.totalBytes - memory.usedBytes
                    UsageBar(segments: [
                        .init(id: "app", value: Double(memory.appBytes), color: .accentColor),
                        .init(id: "wired", value: Double(memory.wiredBytes), color: .orange),
                        .init(id: "compressed", value: Double(memory.compressedBytes), color: .purple),
                        .init(id: "free", value: Double(free), color: Color(nsColor: .quaternaryLabelColor)),
                    ])
                    HStack(spacing: 18) {
                        LegendItem(color: .accentColor, title: "Apps", value: memory.appBytes.formattedMemory)
                            .help("Memory apps hold on to themselves.")
                        LegendItem(color: .orange, title: "Wired", value: memory.wiredBytes.formattedMemory)
                            .help("Memory macOS keeps for itself and can't move out.")
                        LegendItem(color: .purple, title: "Compressed", value: memory.compressedBytes.formattedMemory)
                            .help("Memory squeezed in place to make room.")
                    }
                }
            }
        }
    }
}

private struct PressureBadge: View {
    let pressure: MemoryUsage.Pressure

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .help("How hard macOS has to work to find free memory. High pressure for a long time means the Mac needs more memory than it has.")
    }

    private var label: LocalizedStringResource {
        switch pressure {
        case .normal: "Pressure: normal"
        case .warning: "Pressure: high"
        case .critical: "Pressure: critical"
        }
    }

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// The processor and the graphics processor, one above the other.
private struct ProcessorCard: View {
    let load: Double?
    let gpu: GPUStatus?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                LoadRow(systemImage: "cpu", title: "CPU", detail: nil, load: load)
                Divider()
                LoadRow(systemImage: "display", title: "GPU", detail: gpu?.name, load: gpu?.utilization)
            }
        }
    }
}

private struct LoadRow: View {
    let systemImage: String
    let title: LocalizedStringResource
    let detail: String?
    let load: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let load {
                    Text("\(load.formatted(.percent.precision(.fractionLength(0)))) busy")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: load ?? 0)
                .tint(load ?? 0 > 0.8 ? .orange : .accentColor)
        }
    }
}

private struct HeavyAppRow: View {
    let group: ProcessGroup
    let canQuit: Bool
    let quit: (_ force: Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forFile: URL(filePath: group.bundlePath ?? group.id)))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: group.name)
                    .lineLimit(1)
                if group.isSystem {
                    Text("Part of macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if group.pids.count > 1 {
                    Text("^[\(group.pids.count) process](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text((group.cpuPercent / 100).formatted(.percent.precision(.fractionLength(1))))
                .monospacedDigit()
                .foregroundStyle(group.cpuPercent >= 50 ? Color.orange : Color.primary)
                .frame(width: 70, alignment: .trailing)
            Text((group.gpuPercent / 100).formatted(.percent.precision(.fractionLength(1))))
                .monospacedDigit()
                .foregroundStyle(group.gpuPercent >= 50 ? Color.orange : Color.primary)
                .frame(width: 56, alignment: .trailing)
            Text(group.footprint.formattedMemory)
                .monospacedDigit()
                .foregroundStyle(group.footprint >= 2_000_000_000 ? Color.orange : Color.primary)
                .frame(width: 90, alignment: .trailing)
            Group {
                if canQuit {
                    Button("Quit") { quit(false) }
                } else {
                    Color.clear
                }
            }
            .frame(width: 64, height: 22)
        }
        .contextMenu {
            if canQuit {
                Button("Quit") { quit(false) }
                Button("Force Quit…") { quit(true) }
            }
            if let bundlePath = group.bundlePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: bundlePath)]) }
            }
        }
    }
}
