import SwiftUI

/// Pebble with a pulse: it squashes and stretches as it breathes, blinks while awake, wobbles while
/// thinking, hops when happy, leans toward wherever you touch the screen and bounces when you tap.
/// Falls back to a still image when Reduce Motion is on.
struct LivePebble: View {
    var mood: String
    var size: CGFloat
    /// Finger position in global coordinates, nil when nothing is touching the screen.
    var touch: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var squash: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let lean = leanVector(from: CGPoint(x: frame.midX, y: frame.midY))
            body(lean: lean)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: size, height: size)
        .onChange(of: touch == nil) { _, released in if !released { bounce(0.16) } }
        .onChange(of: mood) { _, _ in bounce(0.12) }
    }

    private func body(lean: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let still = reduceMotion
            let breath = still ? 0 : sin(t * 2.4) * 0.05
            let bob = still ? 0 : sin(t * 1.2) * size * 0.04
            let blink = !still && mood == "awake" && t.truncatingRemainder(dividingBy: 4.3) < 0.14
            let wobble = !still && mood == "thinking" ? sin(t * 5) * 5 : 0
            let hop = !still && mood == "happy" ? -abs(sin(t * 7)) * size * 0.08 : 0

            Image("Pebble-\(blink ? "calm" : mood)")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .scaleEffect(x: 1 + breath, y: 1 - breath, anchor: .bottom)
                .rotationEffect(.degrees(wobble))
                .offset(y: bob + hop)
        }
        .scaleEffect(x: 1 + squash, y: 1 - squash, anchor: .bottom)
        .rotationEffect(.degrees(Double(lean.width) * 9))
        .offset(x: lean.width * size * 0.10, y: lean.height * size * 0.06)
        .animation(.interpolatingSpring(stiffness: 140, damping: 7), value: lean)
    }

    /// -1…1 on each axis: how far the finger is from Pebble's centre, softened.
    private func leanVector(from center: CGPoint) -> CGSize {
        guard let touch, !reduceMotion else { return .zero }
        func soft(_ v: CGFloat) -> CGFloat { max(-1, min(1, v / 220)) }
        return CGSize(width: soft(touch.x - center.x), height: soft(touch.y - center.y))
    }

    private func bounce(_ amount: CGFloat) {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.07)) { squash = amount }
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 5)) { squash = 0 }
        }
    }
}
