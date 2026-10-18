import SwiftUI

/// The one Pebble. It opens the app big in the middle, flies up into the top bar and stays there,
/// and wanders around the screen while Aide works on a long task.
struct PebbleStage: View {
    let area: CGSize
    let dockedY: CGFloat
    @Binding var introDone: Bool
    let busy: Bool
    let mood: String
    let touch: CGPoint?

    private enum Stage { case intro, docked }
    private static let bigSize: CGFloat = 480
    private static let dockedSize: CGFloat = 44
    private static let roamSize: CGFloat = 78

    @State private var busyNow = false
    @State private var roamStart: Date?
    @State private var roamEnd: Date?

    private var stage: Stage { !introDone ? .intro : .docked }

    var body: some View {
        TimelineView(.animation(paused: roamStart == nil && roamEnd == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let k = stage == .docked ? roamBlend(context.date) : 0
            let home = homePosition
            let roam = CGPoint(x: area.width / 2 + sin(t * 0.7) * area.width * 0.30,
                               y: area.height * 0.42 + sin(t * 1.1 + 1) * area.height * 0.14)
            LivePebble(mood: stageMood, size: homeSize + (Self.roamSize - Self.dockedSize) * k * (stage == .docked ? 1 : 0),
                       touch: touch, glow: stage == .intro ? 1 : busy ? 1 : 0.5)
                .foregroundStyle(Theme.accent)
                .position(x: home.x + (roam.x - home.x) * k, y: home.y + (roam.y - home.y) * k)
        }
        .animation(.spring(response: 0.85, dampingFraction: 0.6), value: stage)
        .allowsHitTesting(false)
        .task {
            // Starts huge in the middle, then drops into the top bar almost at once.
            guard !introDone else { return }
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { introDone = true }
        }
        .onChange(of: busy) { _, nowBusy in
            busyNow = nowBusy
            if nowBusy {
                Task {
                    try? await Task.sleep(for: .seconds(1.5)) // quick answers don't need a walkabout
                    if busyNow { roamStart = Date(); roamEnd = nil }
                }
            } else if roamStart != nil {
                roamStart = nil
                roamEnd = Date()
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if roamStart == nil { roamEnd = nil }
                }
            }
        }
    }

    private var stageMood: String {
        switch stage {
        case .intro: "happy"
        case .docked: mood
        }
    }

    private var homeSize: CGFloat { stage == .docked ? Self.dockedSize : Self.bigSize }

    private var homePosition: CGPoint {
        switch stage {
        case .intro: CGPoint(x: area.width / 2, y: area.height * 0.40)
        case .docked: CGPoint(x: area.width / 2, y: dockedY)
        }
    }

    /// 0 at the top bar, 1 fully out roaming; eased in and out over ~0.9 s.
    private func roamBlend(_ now: Date) -> CGFloat {
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        if let s = roamStart { return CGFloat(ease(min(1, now.timeIntervalSince(s) / 0.9))) }
        if let e = roamEnd { return CGFloat(ease(max(0, 1 - now.timeIntervalSince(e) / 0.9))) }
        return 0
    }
}
