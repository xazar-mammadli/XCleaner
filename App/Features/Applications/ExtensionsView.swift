import AppKit
import CleanerCore
import SwiftUI

struct ExtensionsView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: ExtensionItem?

    var body: some View {
        let extensions = model.extensions
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Extensions", subtitle: "Add-ons for macOS and for your browsers: preference panes, plug-ins, services and browser extensions.")
                if let report = extensions.lastReport {
                    RemovalSummary(report: report)
                }
                if !extensions.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if extensions.isEmpty {
                    ContentUnavailableView {
                        Label("No extensions", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Nothing was added to macOS or to your browsers.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(ExtensionItem.Kind.allCases, id: \.self) { kind in
                        let items = extensions.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            ExtensionSection(title: kind.title, footnote: kind.summary) {
                                RowsCard(items) { item in
                                    ExtensionRow(item: item) { removing = item }
                                }
                            }
                        }
                    }
                    let browsers = Array(Set(extensions.browserExtensions.map(\.browser))).sorted { $0.name < $1.name }
                    ForEach(browsers, id: \.self) { browser in
                        ExtensionSection(
                            title: "\(browser.name) Extensions",
                            footnote: browser == .safari
                                ? "Safari extensions come inside apps, and go when their app goes."
                                : "Remove these in \(browser.name) itself: browsers put back extensions that disappear behind their back."
                        ) {
                            RowsCard(extensions.browserExtensions.filter { $0.browser == browser }) { item in
                                BrowserExtensionRow(item: item)
                            }
                        } accessory: {
                            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                                Button("Open \(browser.name)") { NSWorkspace.shared.open(app) }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { extensions.load() }
        .confirmationDialog(
            Text("Remove “\(removing?.name ?? "")”?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                if let item = removing {
                    Task { await extensions.remove([item], with: model.makeServices(), method: Preferences.deletionMethod) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Preferences.deletionMethod == .dryRun
                ? "Test Mode is on, so nothing will be removed. You'll see what would have happened." as LocalizedStringResource
                : removing?.isSystemWide == true
                    ? "It goes to the Trash, where you can put it back. It's installed for everyone on this Mac, so macOS will ask for your password."
                    : "It goes to the Trash, where you can put it back.")
        }
    }
}

private struct ExtensionSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringResource
    let footnote: LocalizedStringResource
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(
        title: LocalizedStringResource, footnote: LocalizedStringResource,
        @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.footnote = footnote
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                accessory
            }
            content
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExtensionRow: View {
    let item: ExtensionItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forFile: item.url))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if item.isSystemWide {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Removing this asks for your password.")
            }
            Text(item.size.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
            Button("Remove…", action: remove)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private var detail: String {
        let audience = item.isSystemWide ? String(localized: "For everyone on this Mac") : String(localized: "Only for you")
        return [item.version, audience].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct BrowserExtensionRow: View {
    let item: BrowserExtension

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = item.icon, let image = NSImage(contentsOf: icon) {
                    Image(nsImage: image)
                        .resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(2)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                Text(verbatim: [item.version, item.profile.isEmpty ? nil : item.profile].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
    }
}
