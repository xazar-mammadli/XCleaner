import AppKit
import CleanerCore
import SwiftUI

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.applicationsTool {
            case .uninstaller: UninstallerView()
            case .remainingFiles: RemainingFilesView()
            case .extensions: ExtensionsView()
            }
        }
        .navigationTitle(Text(SidebarItem.applications.title))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $model.applicationsTool) {
                    ForEach(ApplicationsTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                } label: {
                    Text(SidebarItem.applications.title)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Uninstaller

private struct UninstallerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var uninstaller = model.uninstaller
        HStack(spacing: 0) {
            AppList()
                .frame(width: 290)
            Divider()
            AppDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $uninstaller.searchText, placement: .toolbar, prompt: Text("Search apps"))
        .task {
            if !uninstaller.hasLoaded { uninstaller.load(with: model.makeServices()) }
        }
    }
}

private struct AppList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var uninstaller = model.uninstaller
        let apps = uninstaller.visibleApps
        List(selection: selection) {
            ForEach(apps) { app in
                AppRow(app: app, size: uninstaller.sizes[app.url])
                    .tag(app.url)
            }
        }
        .listStyle(.inset)
        // An inset on the list rather than a bar above it, so the list stays the column's first scroll view.
        .safeAreaInset(edge: .top, spacing: 0) {
            if uninstaller.hasLoaded {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("^[\(apps.count) app](inflect: true)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if uninstaller.isMeasuringSizes {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Measuring app sizes…")
                        }
                        Spacer()
                        Picker("Sort by", selection: $uninstaller.order) {
                            ForEach(UninstallerModel.Order.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .fixedSize()
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                .background(.bar)
            }
        }
        .overlay {
            if uninstaller.isLoading {
                ProgressView()
            } else if uninstaller.hasLoaded, apps.isEmpty {
                ContentUnavailableView.search(text: uninstaller.searchText)
            }
        }
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { model.uninstaller.selectedApp?.url },
            set: { url in
                let app = model.uninstaller.apps.first { $0.url == url }
                model.uninstaller.select(app, with: model.makeServices())
            }
        )
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(forFile: app.url))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: app.name)
                    .lineLimit(1)
                if let version = app.version {
                    Text(verbatim: version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: size?.formattedBytes ?? "…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    @State private var runningCheck = 0
    @State private var confirming: UninstallerModel.Action?

    var body: some View {
        let uninstaller = model.uninstaller
        if let app = uninstaller.selectedApp {
            let isRunning = runningCheck >= 0 && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        AppHeader(app: app)
                        if isRunning {
                            Notice(systemImage: "play.circle", tint: .orange, text: "\(app.name) is running. Quit it before uninstalling or resetting.") {
                                Button("Quit \(app.name)") { quit(app) }
                            }
                        }
                        if !uninstaller.fileIssues.isEmpty, model.fullDiskAccess != .granted {
                            Notice(systemImage: "exclamationmark.shield", tint: .orange, text: "Turn on Full Disk Access to also find the app's containers.") {
                                Button("Set Up Access…") { model.isShowingAccessGuide = true }
                            }
                        }
                        if let outcome = uninstaller.outcome {
                            OutcomeBanner(outcome: outcome)
                        }
                        if uninstaller.isFindingFiles {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Looking for the app's files…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            RowsCard(uninstaller.files) { item in
                                CleanableItemRow(item: item, isSelected: uninstaller.binding(for: item))
                            }
                        }
                    }
                    .padding(24)
                }
                footer(app: app, isRunning: isRunning)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                runningCheck += 1
            }
            .confirmationDialog(
                Text(confirmationTitle(for: app)),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    if let action = confirming { Task { await perform(action) } }
                } label: {
                    Text(confirming == .reset ? "Reset" as LocalizedStringResource : "Uninstall")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
        } else if let outcome = uninstaller.outcome {
            VStack(spacing: 14) {
                Image(systemName: outcome.report.requestedMethod == .dryRun ? "testtube.2" : "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(outcome.report.requestedMethod == .dryRun ? Color.orange : Color.green)
                OutcomeBanner(outcome: outcome)
                    .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Choose an app", systemImage: "square.stack.3d.up")
            } description: {
                Text("See everything it keeps on your Mac, then uninstall it completely or reset it to a fresh start.")
            }
        }
    }

    private func footer(app: InstalledApp, isRunning: Bool) -> some View {
        let uninstaller = model.uninstaller
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected: \(uninstaller.selectedBytes.formattedBytes)")
                    .font(.headline)
                    .monospacedDigit()
                Text("Reset keeps the app and removes only its data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if uninstaller.isRemoving, let progress = uninstaller.progress {
                ProgressView(value: progress.fraction)
                    .frame(width: 120)
            }
            Button("Reset") { confirming = .reset }
                .disabled(isRunning || uninstaller.isRemoving || uninstaller.selectedLeftovers.isEmpty)
            Button {
                confirming = .uninstall
            } label: {
                Text("Uninstall")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRunning || uninstaller.isRemoving || !uninstaller.isBundleSelected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func confirmationTitle(for app: InstalledApp) -> LocalizedStringResource {
        confirming == .reset ? "Reset \(app.name)?" : "Uninstall \(app.name)?"
    }

    /// Dialogs only show a plain `Text`, so the message is picked here.
    private var confirmationMessage: LocalizedStringResource {
        if Preferences.deletionMethod == .dryRun {
            return "Test Mode is on, so nothing will be removed. You'll see what would have happened."
        }
        return confirming == .reset
            ? "Its settings and data will be removed, so it starts fresh the next time you open it. The app itself stays."
            : "The app and the selected files will be removed. The app goes to the Trash, where you can put it back."
    }

    private func perform(_ action: UninstallerModel.Action) async {
        await model.uninstaller.perform(action, with: model.makeServices(), method: Preferences.deletionMethod)
        model.refresh()
    }

    private func quit(_ app: InstalledApp) {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier) {
            running.terminate()
        }
    }
}

private struct AppHeader: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: FileIcons.icon(forFile: app.url))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: app.name)
                    .font(.title.weight(.semibold))
                Text(verbatim: [app.version, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }
}

private struct OutcomeBanner: View {
    @Environment(AppModel.self) private var model
    let outcome: UninstallerModel.Outcome

    var body: some View {
        let report = outcome.report
        let skipped = report.blocked.count + report.failed.count
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: report.requestedMethod == .dryRun ? "testtube.2" : "checkmark.circle.fill")
                .foregroundStyle(report.requestedMethod == .dryRun ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                if report.requestedMethod == .dryRun {
                    Text("Test run: \(report.removedBytes.formattedBytes) would have been removed.")
                        .foregroundStyle(.secondary)
                } else if report.trashedBytes > 0 {
                    Text("Moved to the Trash: \(report.trashedBytes.formattedBytes)")
                        .foregroundStyle(.secondary)
                }
                if report.deletedBytes > 0 {
                    Text("Deleted for good: \(report.deletedBytes.formattedBytes)")
                        .foregroundStyle(.secondary)
                }
                if skipped > 0 {
                    Text("Skipped: ^[\(skipped) item](inflect: true)")
                        .foregroundStyle(.orange)
                    ForEach(report.failed, id: \.item.url) { failure in
                        Text(verbatim: "\(failure.item.name): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if report.trashedBytes > 0 {
                Button("Open Trash") { model.openTrash() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: LocalizedStringResource {
        if outcome.report.requestedMethod == .dryRun { return "Test run for \(outcome.appName) finished" }
        return outcome.action == .reset ? "\(outcome.appName) was reset" : "\(outcome.appName) was uninstalled"
    }
}

/// A short message with an icon and an optional action, for things the user should know or fix.
struct Notice<Action: View>: View {
    let systemImage: String
    let tint: Color
    let text: LocalizedStringResource
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Remaining Files

private struct RemainingFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        let remaining = model.remainingFiles
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Remaining Files", subtitle: "Files left behind by apps that were already deleted.")
                    if !remaining.issues.isEmpty, model.fullDiskAccess != .granted {
                        Notice(systemImage: "exclamationmark.shield", tint: .orange, text: "Turn on Full Disk Access to also check app containers.") {
                            Button("Set Up Access…") { model.isShowingAccessGuide = true }
                        }
                    }
                    if let report = remaining.lastReport {
                        RemovalSummary(report: report)
                    }
                    switch remaining.phase {
                    case .idle, .scanning:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looking for leftovers…")
                                .foregroundStyle(.secondary)
                        }
                    case .results:
                        if remaining.groups.isEmpty {
                            ContentUnavailableView {
                                Label("No leftovers found", systemImage: "checkmark.circle")
                            } description: {
                                Text("Apps you removed didn't leave anything behind.")
                            }
                            .padding(.top, 30)
                        } else {
                            Label("Each entry is named after an app that is no longer installed. Look before you remove: some are shared by several apps.", systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ForEach(remaining.groups) { group in
                                OrphanGroupCard(group: group)
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if remaining.phase == .results, !remaining.groups.isEmpty {
                footer
            }
        }
        .task {
            if remaining.phase == .idle { remaining.scan(with: model.makeServices()) }
        }
        .confirmationDialog(
            Text("Remove \(remaining.selectedBytes.formattedBytes)?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await remaining.removeSelected(with: model.makeServices(), method: Preferences.deletionMethod)
                    model.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : "The selected files go to the Trash, unless Settings say to delete them right away.")
        }
    }

    private var footer: some View {
        let remaining = model.remainingFiles
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Found \(remaining.foundBytes.formattedBytes) from ^[\(remaining.groups.count) app](inflect: true)")
                    .font(.headline)
                Text("Selected: \(remaining.selectedBytes.formattedBytes)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if remaining.isRemoving, let progress = remaining.progress {
                ProgressView(value: progress.fraction)
                    .frame(width: 120)
            }
            Button("Scan Again") { remaining.scan(with: model.makeServices()) }
                .disabled(remaining.isRemoving)
            Button {
                isConfirming = true
            } label: {
                Text("Remove")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(remaining.selectedItems.isEmpty || remaining.isRemoving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct OrphanGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: OrphanGroup

    var body: some View {
        let remaining = model.remainingFiles
        let isExpanded = remaining.expanded.contains(group.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Collapse" as LocalizedStringResource : "Expand"))

                Toggle(sources: group.items.map { remaining.binding(for: $0) }, isOn: \.self) {
                    Text(verbatim: group.displayName)
                }
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.displayName)
                        .fontWeight(.semibold)
                    Text(verbatim: group.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = group.items.first?.note {
                        Text(note.label)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { toggle() } }
                Spacer()
                Text(group.totalBytes.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            if isExpanded {
                Divider()
                ForEach(group.items) { item in
                    CleanableItemRow(item: item, isSelected: remaining.binding(for: item))
                        .padding(.leading, 36)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func toggle() {
        let remaining = model.remainingFiles
        if remaining.expanded.contains(group.id) {
            remaining.expanded.remove(group.id)
        } else {
            remaining.expanded.insert(group.id)
        }
    }
}

/// What the last removal did, with a way to the Trash.
struct RemovalSummary: View {
    @Environment(AppModel.self) private var model
    let report: CleaningReport

    var body: some View {
        let skipped = report.blocked.count + report.failed.count
        HStack(spacing: 10) {
            Image(systemName: report.requestedMethod == .dryRun ? "testtube.2" : "checkmark.circle.fill")
                .foregroundStyle(report.requestedMethod == .dryRun ? Color.orange : Color.green)
            if report.requestedMethod == .dryRun {
                Text("Test run: \(report.removedBytes.formattedBytes) would have been removed.")
            } else if report.trashedBytes > 0 {
                Text("Moved to the Trash: \(report.trashedBytes.formattedBytes)")
            } else {
                Text("Deleted for good: \(report.deletedBytes.formattedBytes)")
            }
            if skipped > 0 {
                Text("Skipped: ^[\(skipped) item](inflect: true)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if report.trashedBytes > 0 {
                Button("Open Trash") { model.openTrash() }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
