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
                    proposal: placed.proposal)
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var width: CGFloat
        var items: [(index: Int, x: CGFloat, proposal: ProposedViewSize)]
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, width: 0, items: [])
        for (index, subview) in subviews.enumerated() {
            // Ideal size first. A child too wide for ANY row — a long
            // filename with wrapping on — is re-measured constrained to
            // the row width, which is what lets multi-line Text actually
            // wrap: measured only at .unspecified it reports one ideal
            // line forever, and the "Wrap" view option did nothing.
            var size = subview.sizeThatFits(.unspecified)
            var proposal = ProposedViewSize.unspecified
            if size.width > width, width.isFinite {
                proposal = ProposedViewSize(width: width, height: nil)
                size = subview.sizeThatFits(proposal)
            }
            let x = current.items.isEmpty ? 0 : current.width + spacing
            if !current.items.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row(
                    y: current.y + current.height + spacing, height: 0, width: 0, items: [])
                current.items.append((index, 0, proposal))
                current.width = size.width
            } else {
                current.items.append((index, x, proposal))
                current.width = x + size.width
            }
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
