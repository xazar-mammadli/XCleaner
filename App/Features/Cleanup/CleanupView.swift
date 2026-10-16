import AppKit
import CleanerCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.cleanup.phase {
            case .idle:
                CleanupIntro()
            case .scanning, .review:
                CleanupReview()
            case .cleaning:
                ProgressView("Cleaning…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished:
                CleanupSummary()
            }
        }
        .navigationTitle(Text(SidebarItem.cleanup.title))
    }
}

private struct CleanupIntro: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: SidebarItem.cleanup.title, subtitle: SidebarItem.cleanup.summary)
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(CleanupModel.Group.Kind.allCases) { kind in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                        .fontWeight(.semibold)
                                    Text(kind.summary)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: kind.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Divider()
                        HStack {
                            Label("Nothing is removed until you review it.", systemImage: "eye")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                model.cleanup.scan(with: model.makeServices())
                            } label: {
                                Label("Scan", systemImage: "magnifyingglass")
                                    .padding(.horizontal, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                ComingLaterSection(item: .cleanup)
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CleanupReview: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<CleanupModel.Group.Kind> = []
    @State private var isConfirming = false

    var body: some View {
        let cleanup = model.cleanup
        VStack(spacing: 0) {
            List {
                ForEach(cleanup.groups) { group in
                    DisclosureGroup(isExpanded: expansion(of: group.kind)) {
                        ForEach(group.items) { item in
                            CleanableItemRow(item: item, isSelected: cleanup.binding(for: item))
                        }
                    } label: {
                        GroupHeader(group: group)
                    }
                }
            }
            .listStyle(.inset)

            ReviewFooter(isConfirming: $isConfirming)
        }
        .confirmationDialog(
            Text("Clean \(cleanup.selectedBytes.formattedBytes)?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await clean() }
            } label: {
                Text(confirmTitle)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            confirmationMessage(for: cleanup.selectedItems, method: Preferences.deletionMethod)
        }
    }

    /// Spells out what confirming will do, item counts included. Dialogs only show plain `Text`, so this builds one.
    private func confirmationMessage(for items: [CleanableItem], method: DeletionMethod) -> Text {
        if method == .dryRun {
            return Text("Test Mode is on, so nothing will be removed. You'll see what would have happened.")
        }
        let planned = items.map { Cleaner.plannedMethod(for: $0, requested: method) }
        let trashed = planned.filter { $0 == .moveToTrash }.count
        let deleted = planned.filter { $0 == .deletePermanently }.count
        let trashing = Text("Moving to the Trash: ^[\(trashed) item](inflect: true). You can restore anything from there.")
        let deleting = Text("Deleting for good: ^[\(deleted) item](inflect: true). This can't be undone.")
        if trashed > 0, deleted > 0 {
            return trashing + Text(verbatim: "\n") + deleting
        }
        return deleted > 0 ? deleting : trashing
    }

    private var confirmTitle: LocalizedStringResource {
        Preferences.deletionMethod == .dryRun ? "Run Test" : "Clean"
    }

    private func expansion(of kind: CleanupModel.Group.Kind) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(kind) },
            set: { isExpanded in
                if isExpanded { expanded.insert(kind) } else { expanded.remove(kind) }
            }
        )
    }

    private func clean() async {
        await model.cleanup.clean(with: model.makeServices(), method: Preferences.deletionMethod)
        model.refresh()
    }
}

private struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: CleanupModel.Group

    var body: some View {
        let cleanup = model.cleanup
        HStack(spacing: 12) {
            Group {
                // An empty group would otherwise show as checked, since all of its zero items are "selected".
                if group.items.isEmpty {
                    Toggle(isOn: .constant(false)) { Text(group.kind.title) }
                } else {
                    Toggle(sources: group.items.map { cleanup.binding(for: $0) }, isOn: \.self) {
                        Text(group.kind.title)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(group.items.isEmpty)

            Image(systemName: group.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.kind.title)
                    .font(.headline)
                Text(group.kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !group.issues.isEmpty {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .help("Some folders could not be read. Turn on Full Disk Access to include them.")
            }
            if group.isScanning {
                ProgressView()
                    .controlSize(.small)
            } else if group.items.isEmpty {
                Text(emptyStatus)
                    .foregroundStyle(.secondary)
            } else {
                Text(group.totalBytes.formattedBytes)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
    }

    private var emptyStatus: LocalizedStringResource {
        if group.wasStopped { return "Stopped" }
        return group.issues.isEmpty ? "Nothing found" : "Needs Full Disk Access"
    }
}

private struct ReviewFooter: View {
    @Environment(AppModel.self) private var model
    @Binding var isConfirming: Bool

    var body: some View {
        let cleanup = model.cleanup
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if cleanup.phase == .scanning {
                    Text("Scanning…")
                        .font(.headline)
                } else {
                    Text("Found \(cleanup.foundBytes.formattedBytes)")
                        .font(.headline)
                }
                Text("Selected: \(cleanup.selectedBytes.formattedBytes)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if cleanup.phase == .scanning {
                Button("Stop") { cleanup.cancel() }
            } else {
                Button("Scan Again") { cleanup.scan(with: model.makeServices()) }
                Button {
                    isConfirming = true
                } label: {
                    Text("Clean \(cleanup.selectedBytes.formattedBytes)")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(cleanup.selection.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct CleanupSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let report = model.cleanup.report {
            let isTest = report.requestedMethod == .dryRun
            let skipped = report.blocked.map { ($0.item, Text($0.reason.label)) } + report.failed.map { ($0.item, Text(verbatim: $0.message)) }
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: isTest ? "testtube.2" : "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(isTest ? Color.orange : Color.green)
                    Text(isTest ? "Test run finished" as LocalizedStringResource : "Cleanup finished")
                        .font(.largeTitle.weight(.semibold))
                    Text(isTest
                        ? "Nothing was removed, because Test Mode is on." as LocalizedStringResource
                        : "Here's what happened.")
                        .foregroundStyle(.secondary)

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            if isTest {
                                Label("Would be removed: \(report.removedBytes.formattedBytes)", systemImage: "testtube.2")
                            }
                            if report.trashedBytes > 0 {
                                HStack {
                                    Label("Moved to the Trash: \(report.trashedBytes.formattedBytes)", systemImage: "trash")
                                    Spacer()
                                    Button("Open Trash") { model.openTrash() }
                                }
                                Text("Empty the Trash to get this space back.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if report.deletedBytes > 0 {
                                Label("Deleted for good: \(report.deletedBytes.formattedBytes)", systemImage: "xmark.bin")
                            }
                            if !skipped.isEmpty {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(skipped, id: \.0.url) { item, reason in
                                            HStack {
                                                Text(verbatim: item.name)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                reason
                                                    .foregroundStyle(.secondary)
                                            }
                                            .font(.callout)
                                        }
                                    }
                                    .padding(.top, 6)
                                } label: {
                                    Label("Skipped: ^[\(skipped.count) item](inflect: true)", systemImage: "hand.raised")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 560)

                    HStack {
                        Button("Show History") { model.selection = .utilities }
                        Button("Scan Again") { model.cleanup.scan(with: model.makeServices()) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

extension CleanupModel {
    func binding(for item: CleanableItem) -> Binding<Bool> {
        Binding(
            get: { self.isSelected(item) },
            set: { self.setSelected($0, item) }
        )
    }
}
