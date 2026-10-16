import SwiftUI

/// Marks which development phase brings a tool.
struct PhaseBadge: View {
    let phase: Int

    var body: some View {
        Text("Phase \(phase)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// Shown at the bottom of the sidebar while Test Mode is on. Clicking it opens Settings.
struct TestModeBadge: View {
    var body: some View {
        SettingsLink {
            HStack(spacing: 10) {
                Image(systemName: "testtube.2")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Test Mode")
                        .font(.callout.weight(.semibold))
                    Text("Nothing is removed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Test Mode is on. Turn it off when you are ready to remove items.")
    }
}
