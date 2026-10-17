import SwiftUI

enum UtilitiesTool: String, CaseIterable, Identifiable {
    case history, menuBar, hiddenFiles

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .history: "Cleanup History"
        case .menuBar: "Menu Bar Monitor"
        case .hiddenFiles: "Hidden Files"
        }
    }
}

struct UtilitiesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.utilitiesTool {
            case .history: HistoryView()
            case .menuBar: MenuBarMonitorView()
            case .hiddenFiles: HiddenFilesView()
            }
        }
        .navigationTitle(Text(SidebarItem.utilities.title))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $model.utilitiesTool) {
                    ForEach(UtilitiesTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                } label: {
                    Text(SidebarItem.utilities.title)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

private struct MenuBarMonitorView: View {
    @AppStorage(PreferenceKey.showsMenuBarMonitor) private var showsMenuBarMonitor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Menu Bar Monitor", subtitle: "CPU, GPU, memory, disk, network and battery at a glance, from the menu bar.")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show XCleaner in the menu bar", isOn: $showsMenuBarMonitor)
                            .toggleStyle(.switch)
                        Text("XCleaner then keeps running in the menu bar after you close its window. Quit it from there.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("What it shows")
                    .font(.headline)
                Card {
                    MenuBarPanel(isPreview: true)
                }
                .frame(maxWidth: 420)
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
