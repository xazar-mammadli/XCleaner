import AppKit
import CleanerCore
import QuickLook
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false
    @State private var merging: SimilarFolders?
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var duplicates = model.duplicates
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Duplicates", subtitle: "Identical files and folders, compared by their content. One copy of everything always stays.")
                    controls(duplicates)
                    if let report = duplicates.lastReport {
                        RemovalSummary(report: report)
                    }
                    if let merge = duplicates.lastMerge {
                        MergeSummary(report: merge)
                    }
                    if duplicates.lastSkipped > 0, duplicates.lastReport != nil {
                        Label("^[\(duplicates.lastSkipped) copy](inflect: true) stayed, so that a copy of everything is left.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !duplicates.result.issues.isEmpty, model.fullDiskAccess != .granted {
                        Notice(systemImage: "exclamationmark.shield", tint: .orange, text: "Some folders could not be read. Turn on Full Disk Access to include them.") {
                            Button("Set Up Access…") { model.isShowingAccessGuide = true }
                        }
                    }

                    switch duplicates.phase {
                    case .idle:
                        Card {
                            Label {
                                Text("XCleaner compares files by what is in them, not by their names. Smart Select then keeps the best copy of each, and picks the others for the Trash.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.tint)
                            }
                        }
                        ComingLaterSection(item: .files)
                    case .scanning:
                        ScanningProgress(progress: duplicates.progress)
                    case .results:
                        results(duplicates)
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if duplicates.phase == .results, !duplicates.allGroups.isEmpty {
                footer(duplicates)
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $merging) { pair in
            MergeSheet(pair: pair)
        }
        .confirmationDialog(
            Text(verbatim: String(inflecting: "Move ^[\(duplicates.selectedItems.count) copy](inflect: true) to the Trash?")),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                Task {
                    await duplicates.removeSelected(with: model.makeServices(), method: Preferences.deletionMethod)
                    model.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : "One copy of each stays where it is. You can put the others back from the Trash.")
        }
    }

    private func controls(_ duplicates: DuplicatesModel) -> some View {
        @Bindable var duplicates = duplicates
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Look in")
                    .foregroundStyle(.secondary)
                ForEach(duplicates.folders, id: \.self) { folder in
                    FolderChip(url: folder, canRemove: duplicates.folders.count > 1) { duplicates.removeFolder(folder) }
                }
                Button {
                    chooseFolders()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Picker("Minimum size", selection: $duplicates.minimumSize) {
                    ForEach(DuplicatesModel.sizeOptions, id: \.self) { size in
                        Text(verbatim: size.formattedBytes).tag(size)
                    }
                }
                .fixedSize()
                .help("Smaller files are left out of the file list. Folders are always compared with all their files.")
                Spacer()
                if duplicates.phase == .scanning {
                    Button("Stop") { duplicates.cancel() }
                } else {
                    Button {
                        duplicates.scan(with: model.makeServices())
                    } label: {
                        Label(duplicates.phase == .idle ? "Scan" as LocalizedStringResource : "Scan Again", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .disabled(duplicates.isWorking)
    }

    @ViewBuilder
    private func results(_ duplicates: DuplicatesModel) -> some View {
        @Bindable var duplicates = duplicates
        if duplicates.allGroups.isEmpty, duplicates.result.similarFolders.isEmpty {
            ContentUnavailableView {
                Label("No duplicates found", systemImage: "checkmark.circle")
            } description: {
                Text("Every file in these folders is one of a kind.")
            }
            .padding(.top, 30)
        } else {
            HStack(spacing: 12) {
                Picker("Show", selection: $duplicates.kind) {
                    ForEach(DuplicatesModel.Kind.allCases) { kind in
                        (Text(kind.title) + Text(verbatim: " \(duplicates.count(of: kind))")).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if duplicates.kind != .similarFolders {
                    Button {
                        duplicates.smartSelect()
                    } label: {
                        Label("Smart Select", systemImage: "wand.and.stars")
                    }
                    .help("Keeps the best copy of each: in Documents, Pictures, Movies or Music rather than Desktop or Downloads, not named like a copy, and the oldest. A copy on each other disk stays too.")
                    Button("Deselect All") { duplicates.deselectAll() }
                        .disabled(duplicates.selection.isEmpty)
                }
            }
            .disabled(duplicates.isWorking)
            Text("Copies take up \(duplicates.extraBytes.formattedBytes) more than one of each would.")
                .foregroundStyle(.secondary)

            switch duplicates.kind {
            case .files, .folders:
                if duplicates.groups.isEmpty {
                    ContentUnavailableView {
                        Label(duplicates.kind == .files ? "No copied files" as LocalizedStringResource : "No copied folders", systemImage: "checkmark.circle")
                    } description: {
                        Text(duplicates.kind == .files
                            ? "Copies found here are inside copied folders. See Folders." as LocalizedStringResource
                            : "No folder here is a copy of another one.")
                    }
                    .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(duplicates.groups) { group in
                            DuplicateGroupCard(group: group) { previewURL = $0 }
                        }
                    }
                }
            case .similarFolders:
                if duplicates.result.similarFolders.isEmpty {
                    ContentUnavailableView {
                        Label("No similar folders", systemImage: "checkmark.circle")
                    } description: {
                        Text("No two folders share most of their files.")
                    }
                    .padding(.top, 20)
                } else {
                    RowsCard(duplicates.result.similarFolders) { pair in
                        SimilarFoldersRow(pair: pair) { merging = pair }
                    }
                    Text("Folders that share most of their files, such as a folder and an older copy of it. Merging leaves one folder with everything from both.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func footer(_ duplicates: DuplicatesModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(duplicates.selectedItems.count) copy](inflect: true) selected")
                    .font(.headline)
                Text("Frees \(duplicates.selectedBytes.formattedBytes) once the Trash is emptied")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if duplicates.isWorking {
                if let progress = duplicates.removalProgress {
                    ProgressView(value: progress.fraction)
                        .frame(width: 140)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Button {
                isConfirming = true
            } label: {
                Text("Move to Trash")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(duplicates.selection.isEmpty || duplicates.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK {
            model.duplicates.addFolders(panel.urls)
        }
    }
}

/// A folder to look in, with a button to leave it out again.
private struct FolderChip: View {
    let url: URL
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isHome ? "house" : "folder")
                .foregroundStyle(.secondary)
            if isHome {
                Text("Home Folder")
            } else {
                Text(verbatim: FileManager.default.displayName(atPath: url.path(percentEncoded: false)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Leave out")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(Text(verbatim: (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath))
    }

    private var isHome: Bool {
        url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == URL.homeDirectory.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct ScanningProgress: View {
    let progress: DuplicateScanProgress?

    var body: some View {
        if let progress, progress.stage == .comparing {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 420)
                Text("Comparing files of the same size: \(progress.bytesCompared.formattedBytes) of \(progress.bytesToCompare.formattedBytes)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Looked at \(progress?.filesSeen ?? 0) files…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }
}

/// The copies of one file or folder, each with a checkbox.
private struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let preview: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(forFile: group.items[0].url))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: group.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(group.extraSize.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("What removing every copy but one frees.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, item in
                CopyRow(item: item, group: group, preview: preview)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(offset.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
            }
        }
        .padding(.bottom, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var summary: String {
        let copies = String(inflecting: "^[\(group.items.count) copy](inflect: true)")
        if group.isFolders {
            return copies + " · " + String(inflecting: "^[\(group.items[0].fileCount) file](inflect: true) each")
        }
        return copies + " · " + String(localized: "\(group.length.formattedBytes) each")
    }
}

private struct CopyRow: View {
    @Environment(AppModel.self) private var model
    let item: DuplicateItem
    let group: DuplicateGroup
    let preview: (URL) -> Void

    var body: some View {
        let duplicates = model.duplicates
        let isPicked = duplicates.selection.contains(item.url)
        let insidePicked = duplicates.goingFolders.contains { $0.contains(item) }
        HStack(spacing: 10) {
            Toggle(isOn: duplicates.binding(for: item, in: group)) {
                Text(verbatim: item.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isPicked && !duplicates.canPick(item, in: group))
            .help(!isPicked && !duplicates.canPick(item, in: group)
                ? "One copy always stays." as LocalizedStringResource
                : "Pick this copy for the Trash")
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if item.reclaimableSize < item.size {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Shares its space on disk with another copy, so removing it frees little or nothing.")
            }
            if insidePicked {
                SafetyTag(label: "Goes with its folder", tint: .secondary)
            } else if !isPicked {
                SafetyTag(label: "Stays", tint: .green)
            }
            Text(item.size.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .help(Text(verbatim: item.url.path(percentEncoded: false)))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if !item.isFolder {
                Button("Quick Look") { preview(item.url) }
            }
        }
    }

    private var details: String {
        let folder = (item.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        return folder + " · " + item.modified.formatted(.dateTime.year().month().day())
    }
}

private struct SimilarFoldersRow: View {
    let pair: SimilarFolders
    let merge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forFile: pair.first))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: path(pair.first))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: path(pair.second))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("^[\(pair.sharedFiles) file](inflect: true) in common, \(pair.sharedBytes.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Merge…", action: merge)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pair.first, pair.second]) }
        }
    }

    private func path(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

/// Merges one of two similar folders into the other, after showing what will happen.
private struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pair: SimilarFolders
    @State private var keep: URL
    @State private var plan: Result<FolderMerger.Plan, FolderMerger.Refusal>?

    init(pair: SimilarFolders) {
        self.pair = pair
        _keep = State(initialValue: SmartSelect.folderToKeep(pair, home: .homeDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge Folders")
                .font(.title2.weight(.semibold))
            Text("Files the kept folder already has go to the Trash. The others move into it, then the emptied folder goes to the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Keep", selection: $keep) {
                ForEach([pair.first, pair.second], id: \.self) { url in
                    Text(verbatim: (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                        .tag(url)
                }
            }
            .pickerStyle(.radioGroup)
            Group {
                switch plan {
                case nil:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Comparing the folders…")
                            .foregroundStyle(.secondary)
                    }
                case .failure(let refusal):
                    Label {
                        Text(refusal.label)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                case .success(let plan):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("To the Trash: ^[\(plan.duplicates.count) file](inflect: true) that “\(name(plan.keep))” already has", systemImage: "trash")
                        Label("Into “\(name(plan.keep))”: ^[\(plan.moves.count) file](inflect: true) it doesn't have yet", systemImage: "arrow.right.doc.on.clipboard")
                        Label("Then the emptied “\(name(plan.other))” goes to the Trash", systemImage: "folder")
                    }
                }
            }
            .frame(minHeight: 70, alignment: .topLeading)
            if Preferences.deletionMethod == .dryRun {
                Label("Test Mode is on, so nothing will change. You'll see what would have happened.", systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard case .success(let plan) = plan else { return }
                    dismiss()
                    Task {
                        await model.duplicates.merge(plan, with: model.makeServices(), method: Preferences.deletionMethod)
                        model.refresh()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task(id: keep) {
            plan = nil
            plan = await model.duplicates.plan(merging: pair, keep: keep, with: model.makeServices())
        }
    }

    private var isReady: Bool {
        if case .success = plan { return true }
        return false
    }

    private func name(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }
}

/// What the last merge did, with a way to the Trash.
private struct MergeSummary: View {
    @Environment(AppModel.self) private var model
    let report: FolderMerger.Report

    var body: some View {
        let copies = report.duplicates.removed.count
        HStack(spacing: 10) {
            Image(systemName: report.method == .dryRun ? "testtube.2" : "checkmark.circle.fill")
                .foregroundStyle(report.method == .dryRun ? Color.orange : Color.green)
            if report.method == .dryRun {
                Text("Test run: ^[\(report.moved.count) file](inflect: true) would have moved, and ^[\(copies) copy](inflect: true) would have gone to the Trash.")
            } else {
                Text("Merged: ^[\(report.moved.count) file](inflect: true) moved, and ^[\(copies) copy](inflect: true) went to the Trash.")
            }
            if report.filesLeft > 0 || !report.failures.isEmpty {
                Text("Some files stayed where they were.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if report.method != .dryRun {
                Button("Open Trash") { model.openTrash() }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension FolderMerger.Refusal {
    var label: LocalizedStringResource {
        switch self {
        case .missing: "One of the folders is gone. Scan again."
        case .nested: "One folder is inside the other."
        case .differentDisks: "The folders are on different disks. Moving between disks means copying, which is better left to Finder."
        case .unsupportedItem(let path): "“\(FileManager.default.displayName(atPath: path))” is a link, a package such as an app, a hidden folder or a file kept in the cloud. XCleaner only merges plain files and folders."
        case .protectedLocation: "One of the folders is in a protected or excluded location."
        case .readOnly(let path): "“\(FileManager.default.displayName(atPath: path))” is read-only, so files can't be moved in or out of it."
        }
    }
}
