import CleanerCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: SidebarItem.overview.title, subtitle: SidebarItem.overview.summary)
                if let disk = model.startupDisk {
                    DiskUsageCard(usage: disk)
                }
                AccessCard(status: model.fullDiskAccess) {
                    model.isShowingAccessGuide = true
                }
                HStack(alignment: .top, spacing: 16) {
                    QuickCleanupCard()
                    SafetyCard()
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(SidebarItem.overview.title))
    }
}

private struct DiskUsageCard: View {
    let usage: VolumeUsage

    private let usedColor = Color.accentColor
    private let purgeableColor = Color.gray.opacity(0.55)
    private let freeColor = Color(nsColor: .quaternaryLabelColor)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive")
                        .font(.title)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: usage.name)
                            .font(.headline)
                        Text("\(format(usage.availableBytes)) available of \(format(usage.totalBytes))")
                            .foregroundStyle(.secondary)
                    }
                }
                UsageBar(segments: [
                    .init(id: "used", value: Double(usage.usedBytes), color: usedColor),
                    .init(id: "purgeable", value: Double(usage.purgeableBytes), color: purgeableColor),
                    .init(id: "free", value: Double(usage.freeBytes), color: freeColor),
                ])
                HStack(spacing: 22) {
                    LegendItem(color: usedColor, title: "Used", value: format(usage.usedBytes))
                    LegendItem(color: purgeableColor, title: "Purgeable", value: format(usage.purgeableBytes))
                        .help("Space macOS frees on its own when it needs it, such as local snapshots and optimized iCloud copies.")
                    LegendItem(color: freeColor, title: "Free", value: format(usage.freeBytes))
                }
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

private struct LegendItem: View {
    let color: Color
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .monospacedDigit()
        }
        .font(.callout)
    }
}

private struct AccessCard: View {
    let status: FullDiskAccessStatus
    let setUp: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: status == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(status == .granted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if status != .granted {
                    Button("Set Up Access…", action: setUp)
                }
            }
        }
    }

    private var title: LocalizedStringResource {
        switch status {
        case .granted: "Full Disk Access is on"
        case .denied: "Full Disk Access is off"
        case .unknown: "Couldn't check Full Disk Access"
        }
    }

    private var message: LocalizedStringResource {
        status == .granted
            ? "XCleaner can check every location it cleans."
            : "Without it, XCleaner can't see some caches, logs and app leftovers."
    }
}

private struct QuickCleanupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Quick Cleanup", systemImage: "sparkles")
                    .font(.headline)
                Text("Finds caches, logs and other junk that is safe to remove. You review everything before anything is removed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.startQuickCleanup()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct SafetyCard: View {
    @AppStorage(PreferenceKey.removalMethod) private var removalMethod = RemovalMethod.trash

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("How XCleaner keeps you safe", systemImage: "lock.shield")
                    .font(.headline)
                SafetyPoint(systemImage: "eye", text: "Nothing is removed until you review it.")
                SafetyPoint(
                    systemImage: "arrow.uturn.backward",
                    text: removalMethod == .trash
                        ? "Removed items go to the Trash, so you can put them back."
                        : "Your personal files always go to the Trash first."
                )
                SafetyPoint(systemImage: "lock", text: "System files and personal data are protected.")
                SafetyPoint(systemImage: "list.bullet.rectangle", text: "Every action is recorded in the cleanup history.")
            }
        }
    }
}

private struct SafetyPoint: View {
    let systemImage: String
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}

#Preview {
    OverviewView()
        .environment(AppModel())
        .frame(width: 820, height: 680)
}
