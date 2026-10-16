import SwiftUI

/// A long list of rows inside a card, with alternating backgrounds. It is built from a lazy stack rather than a `List`
/// or `Table`, which ask for their full content height and push the window layout around. It sits in the page's scroll
/// view, or scrolls on its own when the rest of the page should stay put.
///
/// Rows get their element, never an index into model state: when the model swaps its array (another app selected,
/// say), rows still on screen would otherwise read past the end of the new one before the card is rebuilt.
struct RowsCard<Data: RandomAccessCollection, Row: View>: View {
    let data: Data
    /// Whether the rows scroll inside the card, which then grows only as tall as the space it gets.
    let scrolls: Bool
    let row: (Data.Element) -> Row
    @State private var contentHeight: CGFloat?

    init(_ data: Data, scrolls: Bool = false, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.scrolls = scrolls
        self.row = row
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    rows
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // A short list keeps the card short; a long one fills the space and scrolls.
                .frame(maxHeight: contentHeight ?? .infinity)
            } else {
                rows
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.offset) { offset, element in
                row(element)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(offset.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
            }
        }
        .padding(.vertical, 4)
    }
}
