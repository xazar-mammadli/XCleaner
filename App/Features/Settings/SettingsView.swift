import AppKit
import CleanerCore
import SwiftUI

/// Every tab is a grouped form that reports its own height, so the window resizes to fit each tab
/// instead of keeping the size of whichever tab was shown first.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "lock.shield") }
            ExclusionsSettings()
                .tabItem { Label("Exclusions", systemImage: "nosign") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                Text("System Default (\(AppLanguage.systemLanguageName))").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "Azərbaycan dili").tag(AppLanguage.azerbaijani)
            }
            .onChange(of: language) { _, newLanguage in
                newLanguage.save()
            }

            if language != AppLanguage.atLaunch {
                HStack {
                    Text("Restart XCleaner to use the new language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppRelauncher.relaunch() }
                }
            }
        }
        .settingsTabStyle()
    }
}

private struct SafetySettings: View {
    @AppStorage(PreferenceKey.removalMethod) private var removalMethod = RemovalMethod.trash
    @AppStorage(PreferenceKey.testMode) private var testMode = Preferences.defaultTestMode

    var body: some View {
        Form {
            Section {
                Picker("Removed items", selection: $removalMethod) {
                    Text("Move to Trash (recommended)").tag(RemovalMethod.trash)
                    Text("Delete immediately").tag(RemovalMethod.delete)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Files you pick yourself, such as large files and duplicates, always go to the Trash.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Test Mode", isOn: $testMode)
            } footer: {
                Text("Scan and review as usual, but nothing is removed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Cleanup History") {
                    Button("Show in Finder") { revealCleanupHistory() }
                }
            } footer: {
                Text("A record of every removal is kept on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTabStyle()
    }

    private func revealCleanupHistory() {
        let folder = AuditLog.standardDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct ExclusionsSettings: View {
    @Environment(AppModel.self) private var model

    /// Beyond this many entries the tab stops growing and scrolls instead.
    private let visibleRows = 6

    var body: some View {
        let exclusions = model.exclusions
        Form {
            Section {
                if exclusions.paths.isEmpty {
                    Text("No exclusions yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(exclusions.paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Text(verbatim: path))
                        Spacer()
                        Button {
                            exclusions.remove(path)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the list")
                    }
                }
                Button("Add…") { chooseExclusions() }
                    .help("Add a file or folder")
            } footer: {
                Text("XCleaner never scans or removes anything in these locations.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTabStyle(scrollsAfter: exclusions.paths.count > visibleRows ? 380 : nil)
    }

    private func chooseExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Exclude")
        if panel.runModal() == .OK {
            model.exclusions.add(panel.urls)
        }
    }
}

private extension View {
    /// A grouped form that is exactly as tall as its content, or `height` tall and scrolling when that is given.
    func settingsTabStyle(scrollsAfter height: CGFloat? = nil) -> some View {
        formStyle(.grouped)
            .scrollDisabled(height == nil)
            .frame(height: height)
            .fixedSize(horizontal: false, vertical: height == nil)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
