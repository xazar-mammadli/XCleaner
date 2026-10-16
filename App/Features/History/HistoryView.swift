import AppKit
import CleanerCore
import SwiftUI

/// Everything XCleaner removed or refused to remove, newest first.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AuditLog.Entry] = []
    @State private var isLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Cleanup History", subtitle: "Everything XCleaner removed, and when.")
                if isLoaded, entries.isEmpty {
                    ContentUnavailableView {
                        Label("No cleanups yet", systemImage: "clock")
                    } description: {
                        Text("Everything XCleaner removes will be listed here.")
                    }
                    .padding(.top, 40)
                } else {
                    RowsCard(count: entries.count) { index in
                        HistoryRow(entry: entries[index])
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(SidebarItem.utilities.title))
        .toolbar {
            Button {
                let folder = AuditLog.standardDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show in Finder")
        }
        .task {
            entries = await model.auditLog.allEntries()
            isLoaded = true
        }
    }
}

private struct HistoryRow: View {
    let entry: AuditLog.Entry

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(entry.action.label)
            } icon: {
                Image(systemName: entry.action.systemImage)
                    .foregroundStyle(.tint)
            }
            .frame(width: 170, alignment: .leading)
            Text(verbatim: (entry.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: entry.path))
            Spacer(minLength: 12)
            Text(entry.bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(entry.date, format: .dateTime.month().day().hour().minute())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
    }
}
