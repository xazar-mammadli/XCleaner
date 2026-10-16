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
}
