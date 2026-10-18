import SwiftUI

/// Pebble with a pulse: it squashes and stretches as it breathes, blinks while awake, wobbles while
/// thinking, hops when happy, and leans toward the finger. A halo glows behind it.
/// Falls back to a still image when Reduce Motion is on.
struct LivePebble: View {
    var mood: String
    var size: CGFloat
    /// -1…1 per axis: how far to lean toward the finger.
    var lean: CGSize = .zero
    /// 0 = no halo, 1 = full. Pulses; faster while thinking.
    var glow: Double = 0.5
    /// Changes make it squash and bounce.
    var bounceTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var squash: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let still = reduceMotion
            let thinking = mood == "thinking"
            let breath = still ? 0 : sin(t * 2.4) * 0.045
            let bob = still ? 0 : sin(t * 1.2) * size * 0.035
            let sway = still ? 0 : sin(t * 0.8) * 2.5
            let blink = !still && mood == "awake" && t.truncatingRemainder(dividingBy: 4.3) < 0.14
            let wobble = !still && thinking ? sin(t * 5) * 5 : 0
            let hop = !still && mood == "happy" ? -abs(sin(t * 4.5)) * size * 0.06 : 0
            // Every ~7 s it does something on its own: a little hop and a curious tilt.
            let cycle = t.truncatingRemainder(dividingBy: 7)
            let curious = !still && cycle < 0.7 ? sin(cycle / 0.7 * .pi) : 0
            let tilt = !still && cycle < 0.7 ? sin(cycle / 0.7 * 2 * .pi) * 7 : 0
            let halo = glow * (still ? 1 : 0.8 + 0.2 * sin(t * (thinking ? 3.2 : 1.3)))

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.glow.opacity(0.5 * halo), Theme.glow.opacity(0)],
                                         center: .center, startRadius: size * 0.25, endRadius: size * 0.85))
                    .frame(width: size * 1.7, height: size * 1.7)
                Image("Pebble-\(blink ? "calm" : mood)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .scaleEffect(x: 1 + breath, y: 1 - breath, anchor: .bottom)
                    .rotationEffect(.degrees(wobble + sway + tilt))
                    .offset(y: bob + hop - curious * size * 0.07)
            }
            .scaleEffect(x: 1 + squash, y: 1 - squash, anchor: .bottom)
            .rotationEffect(.degrees(Double(lean.width) * 9))
            .offset(x: lean.width * size * 0.10, y: lean.height * size * 0.06)
            .animation(.interpolatingSpring(stiffness: 140, damping: 7), value: lean)
        }
        .frame(width: size, height: size)
        .onChange(of: bounceTrigger) { _, _ in bounce(0.16) }
        .onChange(of: mood) { _, _ in bounce(0.12) }
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
