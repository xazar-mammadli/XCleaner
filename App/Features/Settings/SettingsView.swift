import AppKit
import CleanerCore
import SwiftUI

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

private struct ExclusionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        let exclusions = model.exclusions
        VStack(alignment: .leading, spacing: 10) {
            Text("XCleaner never scans or removes anything in these locations.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(exclusions.paths, id: \.self) { path in
                    Label {
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .help(Text(verbatim: path))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 200)
            .overlay {
                if exclusions.paths.isEmpty {
                    Text("No exclusions yet")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Button {
                    chooseExclusions()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .help("Add a file or folder")
                Button {
                    if let selection { exclusions.remove(selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 16, height: 16)
                }
                .disabled(selection == nil)
                .help("Remove the selected location")
            }
        }
        .padding(20)
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
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
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
        .formStyle(.grouped)
    }

    private func revealCleanupHistory() {
        let folder = AuditLog.standardDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
