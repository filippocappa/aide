import Charts
import SwiftUI

struct ChartCard: View {
    let chart: ChartSpec
    /// 0: before the shift, 1: after; animated between.
    @State private var progress: Double = 1
    @State private var played = false

    static let colors: [Color] = [
        Color(red: 0.24, green: 0.49, blue: 0.69), // ocean
        Color(red: 0.78, green: 0.36, blue: 0.48), // rose
        Color(red: 0.42, green: 0.56, blue: 0.44), // sage
        Color(red: 0.85, green: 0.64, blue: 0.25), // amber
        Color(red: 0.56, green: 0.35, blue: 0.61), // plum
        Color(red: 0.16, green: 0.62, blue: 0.56), // teal
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(chart.title, systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if chart.shifts {
                    Button {
                        play()
                    } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                    .disabled(progress > 0 && progress < 1)
                }
            }
            canvas
                .frame(height: 260)
            if let caption = chart.caption {
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            guard chart.shifts, !played else { return }
            played = true
            progress = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation(.easeInOut(duration: 1.2)) { progress = 1 } }
        }
    }

    private func play() {
        progress = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeInOut(duration: 1.2)) { progress = 1 } }
    }

    private struct Sample: Identifiable {
        let id: String
        let series: String
        let x: Double
        let y: Double
    }

    /// The curve's runs of points on the axes, at `t` between before and after, each run its own line.
    private func samples(_ curve: ChartSpec.Curve, index: Int, t: Double, ghost: Bool = false) -> [Sample] {
        let before = curve.points
        let after = ghost ? nil : curve.after
        var out: [Sample] = []
        var run = 0
        var gap = true
        let count = after.map { $0.count == before.count ? before.count : (t < 0.5 ? before.count : $0.count) } ?? before.count
        for i in 0..<count {
            var x: Double?, y: Double?
            if let after, after.count == before.count {
                let b = before[i], a = after[i]
                x = lerp(b.first ?? nil, a.first ?? nil, t)
                let by = b.count > 1 ? b[1] : nil, ay = a.count > 1 ? a[1] : nil
                y = (by != nil && ay != nil) ? lerp(by, ay, t) : (t < 0.5 ? by : ay)
            } else {
                let p = (after != nil && t >= 0.5) ? after![i] : before[i]
                x = p.first ?? nil
                y = p.count > 1 ? p[1] : nil
            }
            guard let x, let y else { gap = true; continue }
            if gap { run += 1; gap = false }
            out.append(Sample(id: "\(index)-\(ghost)-\(i)", series: "\(index)-\(ghost)-\(run)", x: x, y: y))
        }
        return out
    }

    private func lerp(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a, let b else { return a ?? b }
        return a + (b - a) * t
    }

    private func color(_ i: Int) -> Color { Self.colors[i % Self.colors.count] }

    private var canvas: some View {
        Chart {
            ForEach(Array(chart.curves.enumerated()), id: \.offset) { i, curve in
                if curve.after != nil { // where it was, faint, once it has moved
                    ForEach(samples(curve, index: i, t: 0, ghost: true)) { s in
                        LineMark(x: .value("x", s.x), y: .value("y", s.y), series: .value("curve", s.series))
                            .foregroundStyle(color(i).opacity(0.3 * progress))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                let line = samples(curve, index: i, t: progress)
                ForEach(line) { s in
                    LineMark(x: .value("x", s.x), y: .value("y", s.y), series: .value("curve", s.series))
                        .foregroundStyle(color(i))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: curve.dashed ? [6, 4] : []))
                        .interpolationMethod(.linear)
                }
                if let end = line.last {
                    PointMark(x: .value("x", end.x), y: .value("y", end.y))
                        .symbolSize(0)
                        .annotation(position: .topLeading, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            Text(curve.after != nil && progress > 0.5 ? (curve.afterLabel ?? curve.label) : curve.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color(i))
                        }
                }
            }
            ForEach(Array(chart.points.enumerated()), id: \.offset) { _, p in
                let shown = p.after ? progress : 1
                RuleMark(xStart: .value("x", chart.x.min), xEnd: .value("x", p.x), y: .value("y", p.y))
                    .foregroundStyle(Color.secondary.opacity(0.5 * shown))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(x: .value("x", p.x), yStart: .value("y", chart.y.min), yEnd: .value("y", p.y))
                    .foregroundStyle(Color.secondary.opacity(0.5 * shown))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("x", p.x), y: .value("y", p.y))
                    .foregroundStyle(Theme.accent.opacity(shown))
                    .symbolSize(40)
                    .annotation(position: .topTrailing, spacing: 2) {
                        Text(p.label).font(.caption2.weight(.bold)).opacity(shown)
                    }
            }
        }
        .chartXScale(domain: chart.x.min...chart.x.max)
        .chartYScale(domain: chart.y.min...chart.y.max)
        .chartYAxis { AxisMarks(position: .leading) } // as in a textbook figure
        .chartXAxisLabel(chart.x.label, alignment: .trailing)
        .chartYAxisLabel(chart.y.label, position: .leading, alignment: .center)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame.map({ geo[$0] }) {
                    ForEach(Array(chart.areas.enumerated()), id: \.offset) { i, area in
                        areaPath(area, proxy: proxy, origin: frame.origin)
                            .fill(color(i + 3).opacity(0.18))
                        if let c = centre(area), let at = proxy.position(for: (c.0, c.1)) {
                            Text(area.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .position(x: frame.origin.x + at.x, y: frame.origin.y + at.y)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func areaPath(_ area: ChartSpec.Area, proxy: ChartProxy, origin: CGPoint) -> Path {
        Path { path in
            let points = area.points.compactMap { p -> CGPoint? in
                guard p.count == 2, let at = proxy.position(for: (p[0], p[1])) else { return nil }
                return CGPoint(x: origin.x + at.x, y: origin.y + at.y)
            }
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
    }

    private func centre(_ area: ChartSpec.Area) -> (Double, Double)? {
        let pts = area.points.filter { $0.count == 2 }
        guard !pts.isEmpty else { return nil }
        return (pts.map { $0[0] }.reduce(0, +) / Double(pts.count), pts.map { $0[1] }.reduce(0, +) / Double(pts.count))
    }
}
