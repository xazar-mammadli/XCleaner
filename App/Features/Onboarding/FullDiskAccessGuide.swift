import SwiftUI

/// Explains Full Disk Access and walks the user through granting it. macOS offers no way to ask for it directly.
struct FullDiskAccessGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var isGranted: Bool { model.fullDiskAccess == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: isGranted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(isGranted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isGranted {
                VStack(alignment: .leading, spacing: 10) {
                    Step(number: 1, text: "Click Open System Settings.")
                    Step(number: 2, text: "Turn on XCleaner in the list. If it isn't there, click + and choose XCleaner.")
                    Step(number: 3, text: "If macOS asks, choose Quit & Reopen.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Label("Your files never leave this Mac. XCleaner collects no data.", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                if isGranted {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                    Spacer()
                    Button("Check Again") { model.refresh() }
                    Button("Open System Settings") { model.openFullDiskAccessSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private var title: LocalizedStringResource {
        isGranted ? "Full Disk Access is on" : "Allow Full Disk Access"
    }

    private var message: LocalizedStringResource {
        isGranted
            ? "XCleaner can now check every location it cleans."
            : "XCleaner needs Full Disk Access to look inside protected folders, where caches, logs and app leftovers are kept."
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.18)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    FullDiskAccessGuide()
        .environment(AppModel())
}
