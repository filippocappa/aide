import SwiftUI

/// Pebble with a pulse: it squashes and stretches as it breathes, blinks while awake, wobbles while
/// thinking, hops when happy, and leans toward the finger.
/// Open eyes are drawn in code so they can really close: blinks and switches between open and closed
/// expressions shut the lids first instead of jumping between two pictures.
/// Falls back to a still image when Reduce Motion is on.
struct LivePebble: View {
    var mood: String
    var size: CGFloat
    /// -1…1 per axis: how far to lean toward the finger.
    var lean: CGSize = .zero
    /// 0…1 loudness of the user's voice: the body swells and stretches with it.
    var energy: CGFloat = 0
    /// Changes make it squash and bounce.
    var bounceTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var squash: CGFloat = 0
    @State private var kick: Double = 0
    /// The expression on screen. It trails `mood` while the lids close for a change.
    @State private var shown: String?
    /// 0 closed … 1 open, for open-eyed expressions.
    @State private var lids: CGFloat = 1

    var body: some View {
        let face = shown ?? mood
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let still = reduceMotion
            let thinking = face == "thinking"
            let breath = still ? 0 : sin(t * 2.4) * 0.045
            let bob = still ? 0 : sin(t * 1.2) * size * 0.035
            let sway = still ? 0 : sin(t * 0.8) * 2.5
            let wobble = !still && thinking ? sin(t * 5) * 5 : 0
            let hop = !still && face == "happy" ? -abs(sin(t * 4.5)) * size * 0.06 : 0
            // Every ~7 s it does something on its own: a little hop and a curious tilt.
            let cycle = t.truncatingRemainder(dividingBy: 7)
            let curious = !still && cycle < 0.7 ? sin(cycle / 0.7 * .pi) : 0
            let tilt = !still && cycle < 0.7 ? sin(cycle / 0.7 * 2 * .pi) * 7 : 0

            ZStack {
                if let eyes = PebbleShape.eyes(for: face) {
                    PebbleShape(look: eyes.look, radius: eyes.radius, openness: lids * Self.blink(at: t, still: still))
                        .fill(style: FillStyle(eoFill: true))
                } else {
                    Image("Pebble-\(face)").resizable().scaledToFit()
                }
            }
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
        let wasOpen = PebbleShape.eyes(for: old) != nil, isOpen = PebbleShape.eyes(for: new) != nil
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

/// Pebble with round eyes cut out, on the brand's 256 grid (brand/pebble.py), so the lids can animate.
struct PebbleShape: Shape {
    /// Where the eyes look, in grid units from their resting place.
    var look: CGSize
    var radius: CGFloat
    var openness: CGFloat

    /// Eye placement for the expressions with open eyes; nil for the closed-eyed ones (drawn from the images).
    static func eyes(for mood: String) -> (look: CGSize, radius: CGFloat)? {
        switch mood {
        case "awake": (.zero, 10)
        case "thinking": (CGSize(width: 8, height: -10), 9) // looking up and to the side
        default: nil
        }
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(look.width, look.height), .init(radius, openness)) }
        set {
            look = CGSize(width: newValue.first.first, height: newValue.first.second)
            radius = newValue.second.first
            openness = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 48, y: 62, width: 160, height: 136), cornerSize: CGSize(width: 68, height: 68))
        let ry = max(radius * openness, 1.2)
        for x: CGFloat in [100, 156] {
            p.addEllipse(in: CGRect(x: x + look.width - radius, y: 124 + look.height - ry, width: radius * 2, height: ry * 2))
        }
        // The artwork is scaled 1.2× about the centre of its 256 tile, then fitted to the frame.
        let s = min(rect.width, rect.height) / 256
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s * 1.2, y: s * 1.2)
            .translatedBy(x: -128, y: -128)
        return p.applying(transform)
    }
}
