import CleanerCore
import SwiftUI

/// Shows what a check for updates found, and installs a newer release.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    title(updates)
                        .font(.title2.weight(.semibold))
                    subtitle(updates)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content(updates)
            HStack {
                Spacer()
                buttons(updates)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private func title(_ updates: UpdateModel) -> some View {
        switch updates.state {
        case .idle, .checking: Text("Checking for Updates…")
        case .upToDate: Text("XCleaner Is Up to Date")
        case .available(let release): Text("XCleaner \(release.version.description) Is Available")
        case .downloading: Text("Downloading the Update…")
        case .installing: Text("Installing the Update…")
        case .failed: Text("The Update Didn't Work")
        }
    }

    @ViewBuilder
    private func subtitle(_ updates: UpdateModel) -> some View {
        switch updates.state {
        case .available: Text("You have \(updates.currentVersion.description).")
        case .upToDate: Text("Version \(updates.currentVersion.description) is the latest.")
        case .installing: Text("XCleaner starts again when it's done.")
        case .failed(let message): Text(verbatim: message)
        case .idle, .checking, .downloading: EmptyView()
        }
    }

    @ViewBuilder
    private func content(_ updates: UpdateModel) -> some View {
        switch updates.state {
        case .idle, .checking, .installing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .downloading(let fraction):
            ProgressView(value: fraction)
        case .available(let release):
            if !release.notes.isEmpty {
                ScrollView {
                    Text(notes(release.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if release.imageURL == nil || !updates.canInstallItself {
                Label("Download it from the release page and drag it into the Applications folder.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .upToDate, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func buttons(_ updates: UpdateModel) -> some View {
        switch updates.state {
        case .available(let release):
            Button("Skip This Version") { updates.skip(release) }
            Button("Later") { updates.isShowingSheet = false }
                .keyboardShortcut(.cancelAction)
            if release.imageURL != nil, updates.canInstallItself {
                Button("Release Page") { updates.openReleasePage(release) }
                Button("Install and Relaunch") { updates.install(release) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Release Page") {
                    updates.openReleasePage(release)
                    updates.isShowingSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        case .failed:
            Button("Open Release Page") {
                updates.openReleasePage()
                updates.isShowingSheet = false
            }
            Button("Close") { updates.isShowingSheet = false }
                .keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("OK") { updates.isShowingSheet = false }
                .keyboardShortcut(.defaultAction)
        case .idle, .checking:
            Button("Cancel") { updates.isShowingSheet = false }
                .keyboardShortcut(.cancelAction)
        case .downloading, .installing:
            EmptyView()
        }
    }

    /// The release notes, with their Markdown shown as formatting.
    private func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
