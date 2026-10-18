import SwiftUI

/// Pebble with a pulse: it breathes, bobs, blinks while awake and wobbles while thinking.
/// Falls back to a still image when Reduce Motion is on.
struct LivePebble: View {
    var mood: String
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let still = reduceMotion
            let breath = still ? 0 : sin(t * 1.8) * 0.035
            let bob = still ? 0 : sin(t * 0.9) * size * 0.03
            let blink = !still && mood == "awake" && t.truncatingRemainder(dividingBy: 4.3) < 0.14
            let wobble = !still && mood == "thinking" ? sin(t * 5) * 5 : 0
            let hop = !still && mood == "happy" ? -abs(sin(t * 7)) * size * 0.08 : 0

            Image("Pebble-\(blink ? "calm" : mood)")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .scaleEffect(x: 1 + breath, y: 1 - breath)
                .rotationEffect(.degrees(wobble))
                .offset(y: bob + hop)
        }
    }
}
