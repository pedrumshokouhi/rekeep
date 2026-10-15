import SwiftUI

/// Places each card in the currently shortest column, so cards of different heights pack
/// without the ragged gaps a row-based grid leaves. Order still reads left-to-right, top-down.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 260
    var spacing: CGFloat = 16

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        // SwiftUI may propose an unbounded or zero width while measuring; fall back to one column.
        guard width.isFinite, width > 0 else { return (1, minColumnWidth) }
        let count = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        return (count, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let (count, columnWidth) = columns(for: width)
        var heights = Array(repeating: CGFloat(0), count: count)
        return subviews.map { view in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: size.height)
            heights[column] += size.height + spacing
            return frame
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? 800
        let width = proposed.isFinite && proposed > 0 ? proposed : minColumnWidth
        let height = frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
