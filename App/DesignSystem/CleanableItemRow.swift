import AppKit
import CleanerCore
import SwiftUI

/// One found item: checkbox, icon, name, what it is, and its size. The full path shows on hover.
struct CleanableItemRow: View {
    let item: CleanableItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isSelected) {
                Text(verbatim: item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: FileIcons.icon(for: item))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ItemDetail(item: item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Safe items carry no tag; the others ask for a closer look.
            if item.safety != .safe {
                SafetyTag(label: item.safety.label, tint: item.safety.tint)
            }
            Text(item.size.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(Text(verbatim: item.url.path(percentEncoded: false)))
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

private struct ItemDetail: View {
    let item: CleanableItem

    var body: some View {
        if let note = item.note {
            Text(note.label)
                .foregroundStyle(.orange)
        } else if let location = item.location {
            Text(location.label)
        } else if let date = item.date {
            Text(item.category.label) + Text(verbatim: " · ") + Text(date, format: .relative(presentation: .named))
        } else {
            Text(item.category.label)
        }
    }
}

/// A small colored tag for items that need a closer look.
struct SafetyTag: View {
    let label: LocalizedStringResource
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Tools of a section that arrive in later phases, listed quietly under the ones that work today.
struct ComingLaterSection: View {
    let item: SidebarItem

    var body: some View {
        let tools = item.plannedTools.filter { $0.phase > SidebarItem.currentPhase }
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Coming later")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(tools) { tool in
                    HStack(spacing: 10) {
                        Image(systemName: tool.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(tool.title)
                        Spacer()
                        PhaseBadge(phase: tool.phase)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
