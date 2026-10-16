import SwiftUI

/// A long list of rows inside a card, with alternating backgrounds. It is built from a lazy stack inside the page's
/// scroll view rather than a `List` or `Table`, which ask for their full content height and push the window layout around.
struct RowsCard<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
            }
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}
