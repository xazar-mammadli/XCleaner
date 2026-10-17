import AppKit
import CleanerCore
import SwiftUI

struct AppPermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var resetting: PermissionsModel.Entry?

    var body: some View {
        @Bindable var permissions = model.permissions
        let sections = permissions.sections
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "App Permissions", subtitle: "Which apps may use your camera, microphone, screen, files and more.")
                if permissions.failure == .accessDenied || (model.fullDiskAccess != .granted && !permissions.hasLoaded) {
                    Notice(systemImage: "exclamationmark.shield", tint: .orange, text: "macOS shows the permissions only to apps with Full Disk Access.") {
                        Button("Set Up Access…") { model.isShowingAccessGuide = true }
                    }
                } else if permissions.failure == .unreadable {
                    Notice(systemImage: "exclamationmark.triangle", tint: .orange, text: "XCleaner couldn't read the permissions on this Mac.") {
                        Button("Open System Settings") { NSWorkspace.shared.open(PrivacyPermission.camera.settingsURL) }
                    }
                } else if !permissions.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    if let kept = permissions.keptAfterReset {
                        Notice(systemImage: "info.circle", tint: .orange, text: "macOS kept the permission of “\(kept.name)”. Change it in System Settings.") {
                            Button("Open System Settings") { NSWorkspace.shared.open(kept.grant.permission.settingsURL) }
                        }
                    }
                    HStack(spacing: 16) {
                        Toggle("Show apps that were refused", isOn: $permissions.showsRefused)
                        Spacer()
                        if permissions.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            permissions.load()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(permissions.isLoading)
                    }
                    if sections.isEmpty {
                        ContentUnavailableView {
                            Label(permissions.searchText.isEmpty ? "No permissions given" as LocalizedStringResource : "No matching apps", systemImage: "hand.raised")
                        } description: {
                            Text(permissions.searchText.isEmpty
                                ? "No app has asked for a permission yet." as LocalizedStringResource
                                : "No app with this name has a permission.")
                        }
                        .padding(.top, 30)
                    }
                    ForEach(sections, id: \.permission) { section in
                        PermissionSection(permission: section.permission, entries: section.entries) { resetting = $0 }
                    }
                    if !sections.isEmpty {
                        Text("Resetting makes macOS forget the answer, so the app asks again the next time it needs the permission. Command-line tools are changed in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $permissions.searchText, placement: .toolbar, prompt: Text("Search apps"))
        .task {
            if !permissions.hasLoaded || permissions.failure != nil { permissions.load() }
        }
        .onChange(of: model.fullDiskAccess) {
            if model.fullDiskAccess == .granted { permissions.load() }
        }
        .confirmationDialog(
            Text(verbatim: resetting.map { String(localized: "Reset \(String(localized: $0.grant.permission.title)) for \($0.name)?") } ?? ""),
            isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset") {
                if let entry = resetting {
                    Task { await permissions.reset(entry) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: resetting.map {
                String(localized: "\($0.name) will ask again the next time it wants to \(String(localized: $0.grant.permission.effect)).")
            } ?? "")
        }
    }
}

private struct PermissionSection: View {
    let permission: PrivacyPermission
    let entries: [PermissionsModel.Entry]
    let reset: (PermissionsModel.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: permission.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(permission.title)
                    .font(.headline)
                Text(verbatim: "\(entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Open in System Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            RowsCard(entries) { entry in
                PermissionRow(entry: entry) { reset(entry) }
            }
        }
    }
}

private struct PermissionRow: View {
    let entry: PermissionsModel.Entry
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let app = entry.appURL {
                    Image(nsImage: FileIcons.icon(forFile: app))
                        .resizable()
                } else {
                    Image(systemName: entry.bundleIdentifier == nil ? "terminal" : "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if entry.bundleIdentifier != nil, entry.appURL == nil {
                SafetyTag(label: "Not installed", tint: .secondary)
            }
            DecisionText(decision: entry.grant.decision)
            if entry.bundleIdentifier != nil {
                Button("Reset…", action: reset)
            }
        }
        .help(Text(verbatim: helpText))
        .contextMenu {
            if let app = entry.appURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
            }
            Button("Open in System Settings") { NSWorkspace.shared.open(entry.grant.permission.settingsURL) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let target = entry.targetName { parts.append(String(localized: "Controls \(target)")) }
        if case .tool(let path) = entry.grant.client { parts.append((path as NSString).abbreviatingWithTildeInPath) }
        if let changed = entry.grant.lastChanged, changed.timeIntervalSince1970 > 0 {
            parts.append(String(localized: "Changed \(changed.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        switch entry.grant.client {
        case .app(let identifier): identifier
        case .tool(let path): path
        }
    }
}

private struct DecisionText: View {
    let decision: PermissionGrant.Decision

    var body: some View {
        switch decision {
        case .allowed:
            Text("Allowed")
                .frame(minWidth: 80, alignment: .trailing)
        case .limited:
            Text("Limited")
                .foregroundStyle(.orange)
                .frame(minWidth: 80, alignment: .trailing)
        case .denied:
            Text("Not allowed")
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}
