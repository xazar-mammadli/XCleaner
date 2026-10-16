import CleanerCore
import SwiftUI

struct MaintenanceView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: MaintenanceTask?

    var body: some View {
        let maintenance = model.maintenance
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Maintenance", subtitle: "Fixes for a few common problems. They change system settings, so each asks for your password.")
                ForEach(MaintenanceTask.allCases) { task in
                    MaintenanceCard(task: task) { confirming = task }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { maintenance.refresh() }
        .confirmationDialog(
            confirming.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Continue") {
                if let task = confirming { maintenance.run(task, method: Preferences.deletionMethod) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: confirming.map { String(localized: $0.confirmation) } ?? "")
        }
    }
}

private struct MaintenanceCard: View {
    @Environment(AppModel.self) private var model
    let task: MaintenanceTask
    let run: () -> Void

    var body: some View {
        let maintenance = model.maintenance
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: task.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.headline)
                    Text(task.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if task == .thinSnapshots, let count = maintenance.snapshotCount {
                        Text(count == 0 ? "There are no local snapshots right now." as LocalizedStringResource : "Local snapshots right now: \(count)")
                            .font(.callout)
                    }
                    if let outcome = maintenance.outcomes[task] {
                        OutcomeLine(outcome: outcome)
                    }
                }
                Spacer(minLength: 12)
                if maintenance.running == task {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Button("Run", action: run)
                        .disabled(maintenance.running != nil || (task == .thinSnapshots && maintenance.snapshotCount == 0))
                }
            }
        }
    }
}

private struct OutcomeLine: View {
    let outcome: MaintenanceModel.Outcome

    var body: some View {
        switch outcome {
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .keptInTestMode:
            Label("Test Mode is on, so the snapshots were kept.", systemImage: "testtube.2")
                .foregroundStyle(.orange)
                .font(.callout)
        case .failed(let message):
            Label {
                Text("It didn't work: \(message)")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
            .font(.callout)
        }
    }
}
