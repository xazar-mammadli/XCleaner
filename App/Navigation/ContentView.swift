import AppKit
import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.hasSeenAccessGuide) private var hasSeenAccessGuide = false
    @AppStorage(PreferenceKey.testMode) private var testMode = Preferences.defaultTestMode

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                if Preferences.hasTestMode, testMode {
                    TestModeBadge()
                }
            }
        } detail: {
            switch model.selection ?? .overview {
            case .overview:
                OverviewView()
            case .cleanup:
                CleanupView()
            case .applications:
                ApplicationsView()
            case .performance:
                PerformanceView()
            case .files:
                FilesView()
            case .privacy:
                PrivacyView()
            case .utilities:
                UtilitiesView()
            case let item:
                SectionRoadmapView(item: item)
            }
        }
        .sheet(isPresented: $model.isShowingAccessGuide) {
            FullDiskAccessGuide()
        }
        .sheet(isPresented: Bindable(model.updates).isShowingSheet) {
            UpdateSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .task {
            if model.fullDiskAccess != .granted, !hasSeenAccessGuide {
                hasSeenAccessGuide = true
                model.isShowingAccessGuide = true
            } else {
                model.updates.checkIfDue()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1000, height: 680)
}
