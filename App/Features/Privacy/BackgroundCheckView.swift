import AppKit
import CleanerCore
import SwiftUI

/// Everything that starts on its own, checked: who signed it, where it lives and how it starts. Changes happen in
/// Performance › Startup Items, which lists the same items.
struct BackgroundCheckView: View {
    @Environment(AppModel.self) private var model
    @State private var showsFine = false

    var body: some View {
        let startup = model.startupItems
        let entries = Self.entries(startup)
        let worth = entries.filter { $0.review.isWorthALook }
        let fine = entries.filter { !$0.review.isWorthALook }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Background Item Check", subtitle: "Who made everything that starts on its own, and whether anything about it is unusual.")
                HStack(spacing: 10) {
                    Button {
                        model.performanceTool = .startupItems
                        model.selection = .performance
                    } label: {
                        Label("Manage in Startup Items", systemImage: "power")
                    }
                    Spacer()
                    if startup.isLoading || startup.isReviewing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        startup.load()
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(startup.isLoading || startup.isReviewing)
                }
                if startup.snapshot == nil || (startup.reviews.isEmpty && startup.isReviewing) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking signatures…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else {
                    Summary(checked: entries.count, worth: worth.count)
                    if !worth.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Worth a Look")
                                .font(.headline)
                            RowsCard(worth) { entry in
                                ReviewRow(entry: entry)
                            }
                        }
                    }
                    if !fine.isEmpty {
                        DisclosureGroup(isExpanded: $showsFine) {
                            RowsCard(fine) { entry in
                                ReviewRow(entry: entry)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Looks Fine")
                                .font(.headline)
                            + Text(verbatim: "  \(fine.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Nothing here is called harmful: XCleaner has no list of bad software. It points out what is unusual, such as a program nobody signed, so you can decide whether you know it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if startup.snapshot == nil, !startup.isLoading { startup.load() }
        }
    }

    struct Entry: Identifiable {
        let id: URL
        let name: String
        let kind: LocalizedStringResource
        let icon: URL?
        let review: BackgroundReview
        /// The job's file or the login item's bundle, for Finder.
        let file: URL
    }

    private static func entries(_ startup: StartupItemsModel) -> [Entry] {
        let jobs = (startup.agents + startup.daemons).compactMap { job -> Entry? in
            guard let review = startup.reviews[job.plistURL] else { return nil }
            return Entry(
                id: job.plistURL, name: startup.name(of: job),
                kind: job.kind == .agent ? "Launch agent" : "Launch daemon",
                icon: startup.owners[job.plistURL], review: review, file: job.plistURL
            )
        }
        let logins = startup.loginItems.compactMap { item -> Entry? in
            guard let review = startup.reviews[item.url] else { return nil }
            return Entry(id: item.url, name: item.name, kind: "Login item", icon: item.url, review: review, file: item.url)
        }
        return (logins + jobs).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct Summary: View {
    let checked: Int
    let worth: Int

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: worth == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(worth == 0 ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    if worth == 0 {
                        Text("Nothing unusual found")
                            .font(.title3.weight(.semibold))
                        Text("^[\(checked) item](inflect: true) checked. None of them looks unusual.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("^[\(worth) item](inflect: true) worth a look")
                            .font(.title3.weight(.semibold))
                        Text("Most are simply old or homemade. Switch off or remove, in Startup Items, the ones you don't know.")
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReviewRow: View {
    let entry: BackgroundCheckView.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: FileIcons.icon(forFile: icon))
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
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .lineLimit(1)
                (Text(entry.kind) + Text(verbatim: " · ") + entry.review.origin.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(entry.review.concerns.enumerated()), id: \.offset) { _, concern in
                    Label {
                        Text(concern.label)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            OriginBadge(origin: entry.review.origin)
        }
        .help(Text(verbatim: entry.review.program ?? entry.file.path(percentEncoded: false)))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }
            if let program = entry.review.program, entry.review.origin != .missing {
                Button("Show Program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: program)]) }
            }
        }
    }
}

private struct OriginBadge: View {
    let origin: CodeOrigin

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .help(origin.text)
    }

    private var symbol: String {
        switch origin {
        case .apple, .appStore, .identifiedDeveloper: "checkmark.seal.fill"
        case .unidentifiedDeveloper, .unsigned, .modified, .missing: "exclamationmark.triangle.fill"
        case .unreadable: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch origin {
        case .apple, .appStore, .identifiedDeveloper: .green
        case .unidentifiedDeveloper, .unsigned, .modified, .missing: .orange
        case .unreadable: .secondary
        }
    }
}

extension CodeOrigin {
    /// Who made it: a developer's own name as it is, the rest in the user's language.
    var text: Text {
        switch self {
        case .apple: Text("Apple")
        case .appStore: Text("Mac App Store")
        case .identifiedDeveloper(let name): name.isEmpty ? Text("Identified developer") : Text(verbatim: name)
        case .unidentifiedDeveloper: Text("Unknown developer")
        case .unsigned: Text("Unsigned")
        case .modified: Text("Signature broken")
        case .missing: Text("Program missing")
        case .unreadable: Text("Couldn't check")
        }
    }
}

extension BackgroundReview.Concern {
    var label: LocalizedStringResource {
        switch self {
        case .programMissing: "The program it should start is gone."
        case .unsigned: "Not signed, so nothing tells who made it."
        case .modified: "Changed after it was signed."
        case .unidentifiedDeveloper: "Signed, but not by a developer Apple knows."
        case .hiddenLocation: "Runs from a hidden folder."
        case .sharedLocation: "Runs from a folder every app may write to."
        case .runsCommand(let command): "Runs a command: \(command)"
        }
    }
}
