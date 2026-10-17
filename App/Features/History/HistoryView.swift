import AppKit
import CleanerCore
import SwiftUI

/// Everything XCleaner removed or refused to remove, narrowed down by kind of action, date and path.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AuditLog.Entry] = []
    @State private var isLoaded = false
    @State private var actionFilter: AuditLog.Entry.Action?
    @State private var period = Period.anyTime
    @State private var order = Order.newestFirst
    @State private var searchText = ""
    @State private var isConfirmingClear = false

    enum Period: String, CaseIterable, Identifiable {
        case anyTime, today, pastWeek, pastMonth

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .anyTime: "Any Time"
            case .today: "Today"
            case .pastWeek: "Past 7 Days"
            case .pastMonth: "Past 30 Days"
            }
        }

        /// The earliest moment shown, or `nil` for the whole history.
        var start: Date? {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            switch self {
            case .anyTime: return nil
            case .today: return today
            case .pastWeek: return calendar.date(byAdding: .day, value: -6, to: today)
            case .pastMonth: return calendar.date(byAdding: .day, value: -29, to: today)
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case newestFirst, oldestFirst, largestFirst

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .newestFirst: "Newest first"
            case .oldestFirst: "Oldest first"
            case .largestFirst: "Largest first"
            }
        }
    }

    var body: some View {
        let rows = visibleEntries
        // Only the table scrolls. The geometry reader at the root keeps the fixed part above it from pushing the
        // window layout around, as a header above a scroll view otherwise does in the detail column.
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Cleanup History", subtitle: "Everything XCleaner removed, and when.")
                if isLoaded, entries.isEmpty {
                    ContentUnavailableView {
                        Label("No cleanups yet", systemImage: "clock")
                    } description: {
                        Text("Everything XCleaner removes will be listed here.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoaded {
                    controls(rows)
                    if !rows.isEmpty {
                        RowsCard(rows, scrolls: true) { entry in
                            HistoryRow(entry: entry)
                        }
                    } else if searchText.isEmpty {
                        ContentUnavailableView {
                            Label("No matching actions", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Nothing in the history matches these filters.")
                        } actions: {
                            Button("Show Everything") {
                                actionFilter = nil
                                period = .anyTime
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search history"))
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
            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Clear History…", systemImage: "trash")
            }
            .help("Clear History…")
            .disabled(entries.isEmpty)
        }
        .confirmationDialog(Text("Clear the cleanup history?"), isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The record of every cleanup is deleted for good. The files on your Mac stay as they are.")
        }
        .task {
            entries = await model.auditLog.allEntries()
            isLoaded = true
        }
    }

    private func clearHistory() async {
        try? await model.auditLog.clear()
        // Reading the log back shows anything that could not be deleted.
        entries = await model.auditLog.allEntries()
    }

    /// The entries that pass the filters, in the chosen order.
    private var visibleEntries: [AuditLog.Entry] {
        let start = period.start
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = entries.filter { entry in
            (actionFilter == nil || entry.action == actionFilter)
                && (start.map { entry.date >= $0 } ?? true)
                && (query.isEmpty || entry.path.localizedStandardContains(query))
        }
        switch order {
        // The log is newest first already, and keeps actions recorded in the same second in the order they happened.
        case .newestFirst: return matching
        case .oldestFirst: return matching.reversed()
        case .largestFirst: return matching.sorted { $0.bytes > $1.bytes }
        }
    }

    private func controls(_ rows: [AuditLog.Entry]) -> some View {
        HStack(spacing: 16) {
            Picker("Show", selection: $actionFilter) {
                Text("All Actions").tag(AuditLog.Entry.Action?.none)
                Divider()
                ForEach(AuditLog.Entry.Action.allCases, id: \.self) { action in
                    Text(action.label).tag(AuditLog.Entry.Action?.some(action))
                }
            }
            .fixedSize()
            Picker("Date", selection: $period) {
                ForEach(Period.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .fixedSize()
            Picker("Sort by", selection: $order) {
                ForEach(Order.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .fixedSize()
            Spacer()
            Text("^[\(rows.count) action](inflect: true), \(rows.reduce(Int64(0)) { $0 + $1.bytes }.formattedBytes)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
                .help(Text(verbatim: entry.action == .moved ? "\(entry.path) → \(entry.detail ?? "")" : entry.path))
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
