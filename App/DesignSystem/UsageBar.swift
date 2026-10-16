import SwiftUI

/// A horizontal bar split into proportional colored segments. Purely visual: the legend next to it carries the numbers.
struct UsageBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.value > 0 }
            let total = visible.reduce(0) { $0 + $1.value }
            let width = proxy.size.width - CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0 ? width * segment.value / total : 0)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// A colored dot, a name and a value, under a `UsageBar`.
struct LegendItem: View {
    let color: Color
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
    }
}
