import SwiftUI

/// Grey shapes in the place of what's loading, with a light sweeping across them, so a page has its shape before its
/// data arrives (instead of a spinner on an empty page).
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.secondary.opacity(0.16))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A list row in waiting: a round mark and two lines of text.
struct SkeletonRow: View {
    var mark = true
    /// The first line's share of the row, so the rows aren't all alike.
    var widths: (CGFloat, CGFloat) = (0.7, 0.45)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if mark { Circle().fill(Color.secondary.opacity(0.16)).frame(width: 22, height: 22) }
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(width: g.size.width * widths.0, height: 14)
                    SkeletonBar(width: g.size.width * widths.1, height: 10)
                }
            }
            .frame(height: 32)
        }
        .padding(.vertical, 4)
        .shimmering()
        .accessibilityHidden(true)
    }

    /// A few rows' widths, varied.
    static let widths: [(CGFloat, CGFloat)] = [(0.72, 0.45), (0.55, 0.62), (0.8, 0.38), (0.6, 0.5)]
}

/// Grouped-list sections in waiting: a header and a few rows each.
struct SkeletonSections: View {
    var sections = 2
    var rows = 2
    var mark = true

    var body: some View {
        ForEach(0..<sections, id: \.self) { s in
            Section {
                ForEach(0..<rows, id: \.self) { r in row(s * rows + r) }
            } header: {
                SkeletonBar(width: 90, height: 12).shimmering()
            }
            .listRowBackground(Theme.row)
        }
    }

    private func row(_ n: Int) -> SkeletonRow {
        let w = SkeletonRow.widths[n % SkeletonRow.widths.count]
        return SkeletonRow(mark: mark, widths: w)
    }
}

/// A page of text in waiting: a heading and a few paragraphs of lines.
struct SkeletonText: View {
    var paragraphs = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SkeletonBar(width: 200, height: 20)
            ForEach(0..<paragraphs, id: \.self) { p in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonBar(height: 11) }
                    SkeletonBar(width: p.isMultiple(of: 2) ? 160 : 220, height: 11)
                }
            }
        }
        .padding(.top, 16)
        .shimmering()
        .accessibilityHidden(true)
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(80, g.size.width * 0.6))
                            .offset(x: phase * (g.size.width + max(80, g.size.width * 0.6)))
                            .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    /// A light sweeping across the view, left to right, while it waits. Still with Reduce Motion.
    func shimmering() -> some View { modifier(Shimmer()) }
}
