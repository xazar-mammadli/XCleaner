import SwiftUI

/// Stands in for a section that is still being built: what it will do, tool by tool, and in which phase.
struct SectionRoadmapView: View {
    let item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: item.title, subtitle: item.summary)
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Coming to this section")
                            .font(.headline)
                            .padding(.bottom, 14)
                        ForEach(Array(item.plannedTools.enumerated()), id: \.element.id) { index, tool in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 10)
                            }
                            ToolRow(tool: tool)
                        }
                    }
                }
                Label("Each tool shows you exactly what it found before anything is removed.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(item.title))
    }
}

private struct ToolRow: View {
    let tool: PlannedTool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tool.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title)
                    .fontWeight(.semibold)
                Text(tool.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            PhaseBadge(phase: tool.phase)
        }
    }
}

#Preview {
    SectionRoadmapView(item: .applications)
        .frame(width: 820, height: 680)
}
