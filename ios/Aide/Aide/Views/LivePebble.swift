import SwiftUI

/// Pebble, or one of its family (`Figure`), with a pulse: it squashes and stretches as it breathes, blinks while
/// awake, wobbles while thinking, hops when happy, and leans toward the finger. Each figure moves at its own pace.
/// Eyes are drawn in code so they can really close: blinks and switches between open and closed expressions
/// shut the lids first instead of jumping between two pictures.
/// Holds still when Reduce Motion is on.
struct LivePebble: View {
    var mood: String
    var size: CGFloat
    /// -1…1 per axis: how far to lean toward the finger.
    var lean: CGSize = .zero
    /// 0…1 loudness of the user's voice: the body swells and stretches with it.
    var energy: CGFloat = 0
    /// Changes make it squash and bounce.
    var bounceTrigger: Int = 0
    var figure: Figure = .pebble

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var squash: CGFloat = 0
    @State private var kick: Double = 0
    /// The expression on screen. It trails `mood` while the lids close for a change.
    @State private var shown: String?
    /// 0 closed … 1 open, for open-eyed expressions.
    @State private var lids: CGFloat = 1

    var body: some View {
        let face = shown ?? mood
        let motion = figure.motion
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * motion.tempo + motion.phase
            let still = reduceMotion
            let thinking = face == "thinking"
            let breath = still ? 0 : sin(t * 2.4) * 0.045
            let bob = still ? 0 : sin(t * 1.2) * size * 0.035 * motion.bounce
            let sway = still ? 0 : sin(t * 0.8) * 2.5
            let wobble = !still && thinking ? sin(t * 5) * 5 : 0
            let hop = !still && face == "happy" ? -abs(sin(t * 4.5)) * size * 0.06 * motion.bounce : 0
            // Every ~7 s it does something on its own: a little hop and a curious tilt.
            let cycle = t.truncatingRemainder(dividingBy: 7)
            let curious = !still && cycle < 0.7 ? sin(cycle / 0.7 * .pi) : 0
            let tilt = !still && cycle < 0.7 ? sin(cycle / 0.7 * 2 * .pi) * 7 : 0

            let eyes = FigureShape.openEyes(for: face)
            FigureShape(figure: figure, face: face, look: eyes?.look ?? .zero, radius: eyes?.radius ?? 10,
                        openness: lids * Self.blink(at: t, still: still))
            .frame(width: size, height: size)
            .scaleEffect(x: 1 + breath, y: 1 - breath, anchor: .bottom)
            .rotationEffect(.degrees(wobble + sway + tilt))
            .offset(y: bob + hop - curious * size * 0.07)
            .scaleEffect(x: 1 + squash - energy * 0.05, y: 1 - squash + energy * 0.14, anchor: .bottom)
            .animation(.easeOut(duration: 0.12), value: energy)
            .rotationEffect(.degrees(Double(lean.width) * 9 + kick))
            .offset(x: lean.width * size * 0.10, y: lean.height * size * 0.06)
            .animation(.interpolatingSpring(stiffness: 140, damping: 7), value: lean)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { bounce(0.2) } // poke it
        .onChange(of: bounceTrigger) { _, _ in bounce(0.16) }
        .onChange(of: mood) { _, new in
            bounce(0.12)
            Task { await change(to: new) }
        }
    }

    /// A blink every ~4.3 s: the lids ease shut and open again over 0.22 s.
    private static func blink(at t: TimeInterval, still: Bool) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 4.3)
        guard !still, phase < 0.22 else { return 1 }
        return 1 - 0.92 * sin(phase / 0.22 * .pi)
    }

    /// Open to open (awake, thinking) glides the eyes over. Anything involving closed eyes shuts the
    /// lids, swaps the expression at the moment they're shut, and opens them again if the new one has open eyes.
    private func change(to new: String) async {
        let old = shown ?? mood
        let wasOpen = FigureShape.openEyes(for: old) != nil, isOpen = FigureShape.openEyes(for: new) != nil
        guard !reduceMotion else { shown = new; lids = 1; return }
        if wasOpen && isOpen {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { shown = new }
            return
        }
        if wasOpen {
            withAnimation(.easeIn(duration: 0.1)) { lids = 0 }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard mood == new else { return } // it changed again meanwhile; that change takes over
        lids = isOpen ? 0 : 1
        shown = new
        if isOpen { withAnimation(.easeOut(duration: 0.16)) { lids = 1 } }
    }

    private func bounce(_ amount: CGFloat) {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.07)) { squash = amount; kick = Bool.random() ? 9 : -9 }
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 5)) { squash = 0; kick = 0 }
        }
    }
}
