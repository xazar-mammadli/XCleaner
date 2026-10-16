import AppKit
import CleanerCore
import SwiftUI

struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        let data = model.browserData
        // The scroll view comes first, the footer below it: see the layout notes in HistoryView.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        title: "Browser Data",
                        subtitle: "History, cookies and caches your browsers keep. Passwords, bookmarks and open tabs are never touched."
                    )
                    if data.issues.contains(where: { if case .accessDenied = $0 { true } else { false } }),
                       model.fullDiskAccess != .granted {
                        Notice(systemImage: "exclamationmark.shield", tint: .orange, text: "Turn on Full Disk Access to include Safari.") {
                            Button("Set Up Access…") { model.isShowingAccessGuide = true }
                        }
                    }
                    if let report = data.lastReport {
                        RemovalSummary(report: report)
                    }
                    if !data.hasScanned {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if data.items.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing to clear", systemImage: "globe")
                        } description: {
                            Text("Your browsers keep no history, cookies or caches right now.")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(data.browsers, id: \.self) { browser in
                            BrowserCard(browser: browser)
                        }
                    }
                    ComingLaterSection(item: .privacy)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if data.hasScanned, !data.items.isEmpty {
                footer(data)
            }
        }
        .navigationTitle(Text(SidebarItem.privacy.title))
        .task {
            if !data.hasScanned { data.scan(hasFullDiskAccess: model.fullDiskAccess == .granted) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            data.refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            data.refreshRunning()
        }
        .confirmationDialog(
            Text("Clear \(data.selectedBytes.formattedBytes) of browser data?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await data.clean(with: model.makeServices(), method: Preferences.deletionMethod) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: confirmationMessage(data))
        }
    }

    private func footer(_ data: BrowserDataModel) -> some View {
        HStack(spacing: 12) {
            Text("Selected: \(data.selectedBytes.formattedBytes)")
                .font(.headline)
                .monospacedDigit()
            Spacer()
            if data.isCleaning || data.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Scan Again") { data.scan(hasFullDiskAccess: model.fullDiskAccess == .granted) }
                .disabled(data.isScanning || data.isCleaning)
            Button {
                isConfirming = true
            } label: {
                Text("Clear")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(data.selectedItems.isEmpty || data.isCleaning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    /// Dialogs only show plain text, so the message is put together here.
    private func confirmationMessage(_ data: BrowserDataModel) -> String {
        if Preferences.deletionMethod == .dryRun {
            return String(localized: "Test Mode is on, so nothing will be removed. You'll see what would have happened.")
        }
        var lines = [
            Preferences.deletionMethod == .deletePermanently
                ? String(localized: "The files are deleted for good. This can't be undone.")
                : String(localized: "The files go to the Trash. Empty it to remove them for good."),
        ]
        let signingOut = data.selectedItems.filter { $0.kind == .cookies }.map(\.browser.name)
        if !signingOut.isEmpty {
            lines.append(String(localized: "You'll be signed out of websites in \(signingOut.formatted(.list(type: .and))).")
            )
        }
        return lines.joined(separator: "\n")
    }
}

private struct BrowserCard: View {
    @Environment(AppModel.self) private var model
    let browser: Browser

    var body: some View {
        let data = model.browserData
        let isRunning = data.isRunning(browser)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Group {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                            Image(nsImage: FileIcons.icon(forFile: app))
                                .resizable()
                        } else {
                            Image(systemName: "globe")
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(verbatim: browser.name)
                        .font(.headline)
                    Spacer()
                    if isRunning {
                        Text("Quit it to clear its data.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Quit \(browser.name)") { data.quit(browser) }
                    }
                }
                ForEach(data.items(of: browser)) { item in
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: data.binding(for: item)) {
                            Text(item.kind.title)
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.title)
                            Text(item.kind.summary)
                                .font(.caption)
                                .foregroundStyle(item.kind == .cookies ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if item.isEmpty {
                            Text("Nothing to clear")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(item.size.formattedBytes)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isRunning || item.isEmpty)
                    .opacity(isRunning || item.isEmpty ? 0.5 : 1)
                }
            }
        }
    }
}
