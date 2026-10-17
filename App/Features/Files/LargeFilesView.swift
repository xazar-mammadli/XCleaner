import AppKit
import CleanerCore
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var order = Order.largestFirst
    @State private var isConfirming = false

    enum Order: String, CaseIterable, Identifiable {
        case largestFirst, oldestFirst, name

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .largestFirst: "Largest first"
            case .oldestFirst: "Oldest first"
            case .name: "Name"
            }
        }
    }

    var body: some View {
        @Bindable var files = model.largeFiles
        let rows = sorted(files.visibleItems)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Biggest & Old Files", subtitle: "Large files you haven't opened in a long time, filtered by type.")
                    controls(files)
                    if files.needsRescan {
                        Label("Scan again to include files this small.", systemImage: "arrow.clockwise")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let report = files.lastReport {
                        RemovalSummary(report: report)
                    }

                    switch files.phase {
                    case .idle:
                        Card {
                            Label {
                                Text("XCleaner looks through your home folder for big files, skipping system files, apps and your photo library. Files you pick go to the Trash.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundStyle(.tint)
                            }
                        }
                        ComingLaterSection(item: .files)
                    case .scanning:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looked at \(files.filesSeen) files…")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    case .results:
                        if rows.isEmpty {
                            ContentUnavailableView {
                                Label("No big files found", systemImage: "checkmark.circle")
                            } description: {
                                Text("Nothing in your home folder is larger than \(files.minimumSize.formattedBytes).")
                            }
                            .padding(.top, 40)
                        } else {
                            RowsCard(rows) { item in
                                LargeFileRow(item: item, isSelected: files.binding(for: item))
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            if files.phase == .results, !rows.isEmpty {
                footer(files, rows: rows)
            }
        }
        .confirmationDialog(
            Text("Move \(files.selectedBytes.formattedBytes) to the Trash?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                Task { await moveToTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Dialogs only show a plain `Text`, so the two cases are picked here rather than with `if`.
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : "You can put the files back from the Trash.")
        }
    }

    /// One row when it fits; in a narrow window or a wordier language, the button moves below the filters.
    private func controls(_ files: LargeFilesModel) -> some View {
        // One row when it fits. Otherwise the filters take the first row and the order shares the second with the
        // scan button, as on the Duplicates page.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                filters(files)
                sortPicker
                Spacer()
                scanButton(files)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) { filters(files) }
                HStack(spacing: 16) {
                    sortPicker
                    Spacer()
                    scanButton(files)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                filters(files)
                HStack(spacing: 16) {
                    sortPicker
                    Spacer()
                    scanButton(files)
                }
            }
        }
        .disabled(files.isRemoving)
    }

    @ViewBuilder
    private func filters(_ files: LargeFilesModel) -> some View {
        @Bindable var files = files
        Picker("Minimum size", selection: $files.minimumSize) {
            ForEach(LargeFilesModel.sizeOptions, id: \.self) { size in
                Text(verbatim: size.formattedBytes).tag(size)
            }
        }
        .fixedSize()
        Picker("Kind", selection: $files.kindFilter) {
            Text("All Kinds").tag(FileKind?.none)
            Divider()
            ForEach(FileKind.allCases, id: \.self) { kind in
                Text(kind.label).tag(FileKind?.some(kind))
            }
        }
        .fixedSize()
    }

    private var sortPicker: some View {
        Picker("Sort by", selection: $order) {
            ForEach(Order.allCases) { order in
                Text(order.label).tag(order)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func scanButton(_ files: LargeFilesModel) -> some View {
        if files.phase == .scanning {
            Button("Stop") { files.cancel() }
        } else {
            Button {
                files.scan(with: model.makeServices())
            } label: {
                Label(files.phase == .idle ? "Scan" as LocalizedStringResource : "Scan Again", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
        }
    }

    private func footer(_ files: LargeFilesModel, rows: [CleanableItem]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(rows.count) file](inflect: true), \(rows.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)")
                    .font(.headline)
                Text("Selected: \(files.selectedBytes.formattedBytes)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !files.issues.isEmpty {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .help("Some folders could not be read. Turn on Full Disk Access to include them.")
            }
            Spacer()
            if files.isRemoving, let progress = files.removalProgress {
                ProgressView(value: progress.fraction)
                    .frame(width: 140)
                Text("\(progress.completed) of ^[\(progress.total) item](inflect: true)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                isConfirming = true
            } label: {
                Text("Move to Trash")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(files.selectedItems.isEmpty || files.isRemoving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func sorted(_ items: [CleanableItem]) -> [CleanableItem] {
        switch order {
        case .largestFirst: items.sorted { $0.size > $1.size }
        case .oldestFirst: items.sorted { $0.sortDate < $1.sortDate }
        case .name: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func moveToTrash() async {
        await model.largeFiles.moveSelectedToTrash(with: model.makeServices(), method: Preferences.deletionMethod)
        model.refresh()
    }
}

/// One big file: checkbox, icon, name and folder, kind, when it was last opened, and size.
private struct LargeFileRow: View {
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
                Text(verbatim: (item.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.kind?.label ?? FileKind.other.label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Group {
                if let date = item.date {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text(verbatim: "—")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .trailing)
            Text(item.size.formattedBytes)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .help(Text(verbatim: item.url.path(percentEncoded: false)))
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}
