import SwiftUI

/// A row that wraps. Chips above the grid and pills under a tile both
/// need one: neither may clip, and neither may force a scroller.
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in layout(subviews, width: bounds.width) {
            for placed in row.items {
                subviews[placed.index].place(
                    at: CGPoint(x: bounds.minX + placed.x, y: bounds.minY + row.y),
                    proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var width: CGFloat
        var items: [(index: Int, x: CGFloat)]
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, width: 0, items: [])
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let x = current.items.isEmpty ? 0 : current.width + spacing
            if !current.items.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row(
                    y: current.y + current.height + spacing, height: 0, width: 0, items: [])
                current.items.append((index, 0))
                current.width = size.width
            } else {
                current.items.append((index, x))
                current.width = x + size.width
            }
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
