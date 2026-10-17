import AppKit
import CleanerCore
import QuickLook
import SwiftUI

struct HiddenFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var trashing: HiddenItem?
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var hidden = model.hiddenFiles
        let isSearch = hidden.results != nil
        let rows = hidden.results ?? hidden.items
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Hidden Files", subtitle: "Show, find and manage the files and folders Finder hides.")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show hidden files in Finder", isOn: Binding(
                            get: { hidden.finderShowsHiddenItems },
                            set: { hidden.setFinderShowsHiddenItems($0) }
                        ))
                        .toggleStyle(.switch)
                        Text("Finder restarts to apply this, and its windows come back. To see hidden files in one Finder window for a while, press ⌘⇧. there instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Text("Look in")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: hidden.isHomeFolder ? "house" : "folder")
                            .foregroundStyle(.secondary)
                        if hidden.isHomeFolder {
                            Text("Home Folder")
                        } else {
                            Text(verbatim: FileManager.default.displayName(atPath: hidden.folder.path(percentEncoded: false)))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                hidden.choose(.homeDirectory, with: model.makeServices())
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Back to the home folder")
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help(Text(verbatim: (hidden.folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath))
                    Button("Choose Folder…") { chooseFolder() }
                    Spacer()
                    if hidden.isLoading || hidden.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    TextField(text: $hidden.query, prompt: Text("Search by name")) {
                        Text("Search by name")
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                }
                if let report = hidden.lastReport {
                    RemovalSummary(report: report)
                }
                if let name = hidden.flagFailure {
                    Notice(systemImage: "exclamationmark.triangle", tint: .orange, text: "macOS didn't let XCleaner change “\(name)”.") {
                        EmptyView()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if isSearch {
                        Text("Hidden items named like “\(hidden.query.trimmingCharacters(in: .whitespaces))”")
                            .font(.headline)
                    } else {
                        Text("Hidden items in this folder")
                            .font(.headline)
                    }
                    if !hidden.hasLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else if rows.isEmpty {
                        Text(isSearch ? "Nothing hidden here has that name." as LocalizedStringResource : "Nothing is hidden here.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        RowsCard(rows) { item in
                            HiddenItemRow(item: item, showsLocation: isSearch, trash: { trashing = item }, preview: { previewURL = item.url })
                        }
                    }
                    Text("Apps and command-line tools keep their settings and data in hidden items, so move one to the Trash only if you know what it is. Keys and passwords are never offered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .quickLookPreview($previewURL)
        .task {
            hidden.refreshFinderSetting()
            if !hidden.hasLoaded { hidden.load(with: model.makeServices()) }
        }
        .task(id: hidden.query) {
            // Waits for a pause in typing.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await hidden.search(with: model.makeServices())
        }
        .confirmationDialog(
            Text(verbatim: trashing.map { String(localized: "Move “\($0.name)” to the Trash?") } ?? ""),
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                if let item = trashing {
                    Task {
                        await hidden.moveToTrash(item, with: model.makeServices(), method: Preferences.deletionMethod)
                        model.refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : "An app or tool that uses it may lose its settings or data. You can put it back from the Trash.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            model.hiddenFiles.choose(url, with: model.makeServices())
        }
    }
}

private struct HiddenItemRow: View {
    @Environment(AppModel.self) private var model
    let item: HiddenItem
    /// Search results come from anywhere below the folder, so they show where they are.
    let showsLocation: Bool
    let trash: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forFile: item.url))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            switch item.role {
            case .credentials:
                SafetyTag(label: "Keys & passwords", tint: .orange)
                    .help("Holds keys, tokens or passwords, so XCleaner never offers to remove it.")
            case .system:
                SafetyTag(label: "macOS", tint: .secondary)
            case .other:
                EmptyView()
            }
            if item.isHiddenByFlag {
                Button("Unhide") { model.hiddenFiles.setHidden(false, item, with: model.makeServices()) }
                    .help("Lets Finder show it. The name doesn't change.")
            } else if !item.hasDotName {
                Button("Hide") { model.hiddenFiles.setHidden(true, item, with: model.makeServices()) }
            }
            Group {
                if let size = item.size {
                    Text(size.formattedBytes)
                } else {
                    Text(verbatim: "—")
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 72, alignment: .trailing)
        }
        .help(Text(verbatim: item.url.path(percentEncoded: false)))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if !item.isFolder {
                Button("Quick Look", action: preview)
            }
            if item.canRemove {
                Divider()
                Button("Move to Trash…", action: trash)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if showsLocation {
            Text(verbatim: (item.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
        } else if item.hasNote {
            Text(item.note)
        } else if let modified = item.modified {
            Text("Changed \(modified.formatted(.relative(presentation: .named)))")
        } else {
            Text(item.isFolder ? "Folder" as LocalizedStringResource : "File")
        }
    }
}
