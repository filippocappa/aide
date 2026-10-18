import SwiftUI

/// The one Pebble. It opens the app big in the middle, drops into the top bar, and wanders
/// around the screen while Aide works on a long task. Everything is state-driven animation,
/// with no per-frame layout, so it can't starve the rest of the screen.
struct PebbleStage: View {
    let area: CGSize
    let dockedY: CGFloat
    let introDone: Bool
    let busy: Bool
    let mood: String
    let touch: CGPoint?
    let tapCount: Int

    private static let bigSize: CGFloat = 480
    private static let dockedSize: CGFloat = 44
    private static let roamSize: CGFloat = 78

    @State private var roaming = false
    @State private var roamTarget = CGPoint.zero
    @State private var busyNow = false

    private var center: CGPoint {
        if !introDone { return CGPoint(x: area.width / 2, y: area.height * 0.40) }
        return roaming ? roamTarget : CGPoint(x: area.width / 2, y: dockedY)
    }

    private var size: CGFloat {
        if !introDone { return Self.bigSize }
        return roaming ? Self.roamSize : Self.dockedSize
    }

    var body: some View {
        LivePebble(mood: introDone ? mood : "happy", size: size, lean: lean,
                   glow: !introDone || busy ? 1 : 0.5, bounceTrigger: tapCount)
            .foregroundStyle(Theme.accent)
            .position(center)
            .animation(.spring(response: 0.7, dampingFraction: 0.65), value: introDone)
            .animation(.easeInOut(duration: 2.2), value: roamTarget)
            .animation(.spring(response: 0.8, dampingFraction: 0.7), value: roaming)
            .allowsHitTesting(false)
            .onChange(of: busy) { _, nowBusy in
                busyNow = nowBusy
                guard nowBusy else { roaming = false; return }
                Task {
                    try? await Task.sleep(for: .seconds(1.5)) // quick answers don't need a walkabout
                    guard busyNow else { return }
                    roaming = true
                    while busyNow {
                        roamTarget = CGPoint(x: .random(in: area.width * 0.2...area.width * 0.8),
                                             y: .random(in: area.height * 0.25...area.height * 0.6))
                        try? await Task.sleep(for: .seconds(2.4))
                    }
                    roaming = false
                }
            }
    }

    /// Lean toward the finger, softened: -1…1 per axis.
    private var lean: CGSize {
        guard let touch else { return .zero }
        func soft(_ v: CGFloat) -> CGFloat { max(-1, min(1, v / 220)) }
        return CGSize(width: soft(touch.x - center.x), height: soft(touch.y - center.y))
    }
}
