import AppKit
import CleanerCore
import SwiftUI

struct StartupItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: [LaunchItem] = []

    var body: some View {
        let startup = model.startupItems
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Startup Items", subtitle: "Everything that starts on its own when you log in or turn on your Mac.")
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Login Items Settings…", systemImage: "gearshape")
                    }
                    Spacer()
                    // The first load has a spinner of its own below.
                    if startup.isLoading, startup.snapshot != nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        startup.load()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(startup.isLoading)
                }
                if let report = startup.lastReport {
                    RemovalSummary(report: report)
                }
                if let label = startup.failedSwitch {
                    Notice(systemImage: "exclamationmark.triangle", tint: .orange, text: "macOS didn't let XCleaner switch “\(label)”.") {
                        EmptyView()
                    }
                }
                if !startup.removable.isEmpty {
                    Notice(
                        systemImage: "exclamationmark.triangle", tint: .orange,
                        text: "^[\(startup.removable.count) startup item](inflect: true) can't run: the program is gone or the file is empty. Such files are usually left behind by deleted apps."
                    ) {
                        Button("Remove…") { removing = startup.removable }
                    }
                }
                if let snapshot = startup.snapshot {
                    StartupSection(
                        title: "Login Items",
                        footnote: "Helpers that apps open at login once you allow it in the app. Switch them off in Login Items Settings.",
                        items: startup.loginItems
                    ) { item in
                        LoginItemRow(item: item, isOn: snapshot.isOn(item))
                    }
                    StartupSection(
                        title: "Launch Agents",
                        footnote: "Background tasks that run while you're logged in. Switching one off keeps it from starting until you switch it on again.",
                        items: startup.agents
                    ) { item in
                        LaunchItemRow(item: item, owner: startup.owners[item.plistURL], snapshot: snapshot) { removing = [item] }
                    }
                    StartupSection(
                        title: "Launch Daemons",
                        footnote: "Background tasks that run for the whole Mac, even before anyone logs in. Switching one asks for your password.",
                        items: startup.daemons
                    ) { item in
                        LaunchItemRow(item: item, owner: startup.owners[item.plistURL], snapshot: snapshot) { removing = [item] }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { startup.load() }
        .confirmationDialog(
            Text(verbatim: String(inflecting: "Remove ^[\(removing.count) startup item](inflect: true)?")),
            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                let items = removing
                Task { await startup.remove(items, with: model.makeServices(), method: Preferences.deletionMethod) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : removing.contains(where: { !$0.isUsers })
                    ? "They go to the Trash, where you can put them back. Some are in the system folders, so macOS will ask for your password."
                    : "They go to the Trash, where you can put them back.")
        }
    }
}

private struct StartupSection<Item, Row: View>: View {
    let title: LocalizedStringResource
    let footnote: LocalizedStringResource
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Text(verbatim: "\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if items.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                RowsCard(items, row: row)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoginItemRow: View {
    let item: LoginItem
    let isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forFile: item.url))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                Text("Comes with \(item.app.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleIdentifier).isEmpty {
                RunningBadge()
            }
            StatusText(isOn: isOn)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}

private struct LaunchItemRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    let owner: URL?
    let snapshot: StartupSnapshot
    let remove: () -> Void

    var body: some View {
        let startup = model.startupItems
        let isOn = snapshot.isOn(item)
        HStack(spacing: 12) {
            Group {
                if let owner {
                    Image(nsImage: FileIcons.icon(forFile: owner))
                        .resizable()
                } else {
                    Image(systemName: "gearshape.2")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: startup.name(of: item))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let problem = item.problem {
                ProblemBadge(problem: problem)
            } else if snapshot.isRunning(item) {
                RunningBadge()
            }
            if startup.canRemove(item) {
                Button("Remove…", action: remove)
            } else if startup.canSwitch(item) {
                Toggle(isOn: Binding(get: { isOn }, set: { startup.setOn($0, item) })) {
                    Text(isOn ? "On" as LocalizedStringResource : "Off")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(startup.switching.contains(item.id))
                .help(
                    startup.needsAdministrator(toSwitch: item)
                        ? "Switching it asks for your password." as LocalizedStringResource
                        : isOn ? "Switch off" : "Switch on"
                )
            } else {
                StatusText(isOn: isOn)
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.plistURL]) }
            if let program = item.program, item.problem != .programMissing {
                Button("Show Program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: program)]) }
            }
        }
    }

    /// The label, unless it is the title already, and when it starts. A broken job starts nothing, so it gets no schedule.
    private var subtitle: String {
        let label = owner == nil ? nil : item.label
        guard item.problem == nil else { return label ?? item.plistURL.lastPathComponent }
        return [label, scheduleText].compactMap { $0 }.joined(separator: " · ")
    }

    private var scheduleText: String {
        let text: LocalizedStringResource = switch item.schedule {
        case .atLaunch: item.kind == .agent ? "Starts at login" : "Starts with the Mac"
        case .alwaysRunning: "Always running"
        case .periodically: "Runs from time to time"
        case .onDemand: "Starts when needed"
        }
        return String(localized: text)
    }
}

private struct StatusText: View {
    let isOn: Bool

    var body: some View {
        Text(isOn ? "On" as LocalizedStringResource : "Off")
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .frame(minWidth: 32, alignment: .trailing)
    }
}

private struct RunningBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text("Running")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ProblemBadge: View {
    let problem: LaunchItem.Problem

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .help(Text(help))
    }

    private var label: LocalizedStringResource {
        switch problem {
        case .empty: "Empty file"
        case .programMissing: "Program missing"
        }
    }

    private var help: LocalizedStringResource {
        switch problem {
        case .empty: "The file names nothing to run, so macOS skips it."
        case .programMissing: "The program it should start is gone, most likely together with its app."
        }
    }
}
