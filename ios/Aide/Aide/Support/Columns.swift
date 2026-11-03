import SwiftUI

/// Cards side by side when there's room, one under another when there isn't: as many columns as fit at
/// `minWidth` each, at most `max`. Rows run left to right; each row is as tall as its tallest card, and every card in
/// it is offered that height (a card with `maxHeight: .infinity` fills it, so tiles in a row match). On the phone
/// it's usually one column (or two small tiles), on the Mac's wide pages two to four.
struct Columns: Layout {
    var max: Int = 2
    var minWidth: CGFloat = 400
    var spacing: CGFloat = 12

    private func count(_ width: CGFloat, _ items: Int) -> Int {
        guard width.isFinite else { return 1 }
        let fit = Int((width + spacing) / (minWidth + spacing))
        return Swift.max(1, Swift.min(max, fit, Swift.max(items, 1)))
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, column: CGFloat, heights: [CGFloat]) {
        let n = count(width, subviews.count)
        let column = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        let heights = stride(from: 0, to: subviews.count, by: n).map { start in
            subviews[start..<Swift.min(start + n, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
                .max() ?? 0
        }
        return (n, column, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let r = rows(width, subviews)
        let height = r.heights.reduce(0, +) + spacing * CGFloat(Swift.max(r.heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in r.heights.enumerated() {
            for i in 0..<r.columns {
                let index = row * r.columns + i
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(i) * (r.column + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: r.column, height: height))
            }
            y += height + spacing
        }
    }
}
