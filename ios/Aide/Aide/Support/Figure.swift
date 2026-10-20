import SwiftUI

/// Pebble's family: each agent is its own little creature, with Pebble's eyes and expressions (brand/pebble.py)
/// on a body shape of its own, so they're told apart by shape as well as colour. Aide, and any agent the app
/// doesn't know yet, is Pebble. Everything is on the brand's 256 grid, and the eyes are holes.
enum Figure: Equatable {
    /// Aide: the wide, smooth stone.
    case pebble
    /// Secretary: a tidy rounded square, like a note card.
    case card
    /// Professor: a tall gumdrop.
    case dome
    /// Coach: a ball.
    case ball
    /// Finance: a gold ingot.
    case ingot

    init(agent id: String?) {
        switch id {
        case "secretary": self = .card
        case "professor": self = .dome
        case "coach": self = .ball
        case "finance": self = .ingot
        default: self = .pebble
        }
    }

    var body: Path {
        switch self {
        case .pebble: Self.pebbleBody
        case .dome: Self.domeBody
        case .ball: Self.ballBody
        case .ingot: Self.ingotBody
        case .card: Self.cardBody
        }
    }

    /// Where the eyes sit: their height, how far each is from the middle, and their size next to Pebble's.
    private var eyes: (y: CGFloat, dx: CGFloat, scale: CGFloat) {
        switch self {
        case .pebble: (124, 28, 1)
        case .dome: (128, 25, 0.92)
        case .ball: (120, 30, 1.05)
        case .ingot: (138, 27, 0.95)
        case .card: (122, 28, 1)
        }
    }

    /// Where open eyes rest, in grid units: a little personality. Coach looks up, eager; Professor down, reading.
    var gaze: CGSize {
        switch self {
        case .pebble, .ingot: .zero
        case .card: CGSize(width: -4, height: 0)
        case .dome: CGSize(width: 0, height: 4)
        case .ball: CGSize(width: 4, height: -4)
        }
    }

    /// How it moves when idle: speed and size of the breathing and bobbing next to Pebble's, and a head start so
    /// a row of them doesn't move in step.
    var motion: (tempo: Double, bounce: CGFloat, phase: Double) {
        switch self {
        case .pebble: (1, 1, 0)
        case .card: (1.1, 1, 1.3)
        case .dome: (0.8, 0.8, 2.9)
        case .ball: (1.25, 1.6, 0.7)
        case .ingot: (0.9, 0.6, 2.1)
        }
    }

    /// The eye holes for an expression. Open eyes (awake, thinking) take `look`, `radius` and `openness`, so they
    /// can glance and blink; the others are drawn as in brand/pebble.py.
    func eyeHoles(face: String, look: CGSize, radius: CGFloat, openness: CGFloat) -> Path {
        let (y, dx, k) = eyes
        var p = Path()
        for cx in [128 - dx, 128 + dx] {
            switch face {
            case "awake", "thinking":
                let r = radius * k, ry = max(r * openness, 1.2)
                let at = CGPoint(x: cx + (look.width + gaze.width) * k, y: y + (look.height + gaze.height) * k)
                p.addEllipse(in: CGRect(x: at.x - r, y: at.y - ry, width: 2 * r, height: 2 * ry))
            case "happy":
                p.addPath(Self.arcEye(CGPoint(x: cx, y: y + 6 * k), k: k, from: 200, to: 340))
            case "sleeping":
                let w = 26 * k, t = 8 * k
                p.addRoundedRect(in: CGRect(x: cx - w / 2, y: y + 8 * k - t / 2, width: w, height: t),
                                 cornerSize: CGSize(width: t / 2, height: t / 2))
            default: // calm
                p.addPath(Self.arcEye(CGPoint(x: cx, y: y), k: k, from: 20, to: 160))
            }
        }
        return p
    }

    /// A thick arc with round ends: 20…160° is the content, closed eye; 200…340° the happy one.
    private static func arcEye(_ c: CGPoint, k: CGFloat, from a0: Double, to a1: Double) -> Path {
        var arc = Path()
        arc.addArc(center: c, radius: 15 * k, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        return arc.strokedPath(StrokeStyle(lineWidth: 11 * k, lineCap: .round))
    }

    // MARK: Bodies

    private static let pebbleBody = Path(roundedRect: CGRect(x: 48, y: 62, width: 160, height: 136), cornerRadius: 68)

    private static let domeBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 60, y: 122))
        p.addArc(center: CGPoint(x: 128, y: 122), radius: 68, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: 196, y: 166))
        p.addArc(tangent1End: CGPoint(x: 196, y: 200), tangent2End: CGPoint(x: 128, y: 200), radius: 34)
        p.addArc(tangent1End: CGPoint(x: 60, y: 200), tangent2End: CGPoint(x: 60, y: 122), radius: 34)
        p.closeSubpath()
        return p
    }()

    /// A tidy rounded square, like a note card.
    private static let cardBody = Path(roundedRect: CGRect(x: 58, y: 58, width: 140, height: 140), cornerRadius: 46,
                                       style: .continuous)

    private static let ballBody = Path(ellipseIn: CGRect(x: 54, y: 54, width: 148, height: 148))

    /// A trapezoid with its corners rounded: the inner outline, thickened by the corner radius.
    private static let ingotBody: Path = {
        var p = Path()
        p.addLines([CGPoint(x: 96, y: 100), CGPoint(x: 160, y: 100), CGPoint(x: 180, y: 168), CGPoint(x: 76, y: 168)])
        p.closeSubpath()
        return p.union(p.strokedPath(StrokeStyle(lineWidth: 56, lineJoin: .round)))
    }()
}

/// A figure with an expression, fitted to the frame. Open eyes animate: where they look, their size, the lids.
struct FigureShape: Shape {
    var figure: Figure
    var face: String
    var look: CGSize = .zero
    var radius: CGFloat = 10
    var openness: CGFloat = 1
    /// How much the artwork is scaled about the centre of its tile: 1.2 for the live one, 1 for the small mark.
    var scale: CGFloat = 1.2

    /// The figure in the surrounding colour, lit from above: a soft highlight on top and a little shade below,
    /// so it reads as a smooth object rather than a flat cut-out.
    func shaded() -> some View {
        overlay(fill(LinearGradient(stops: [.init(color: .white.opacity(0.3), location: 0),
                                            .init(color: .white.opacity(0), location: 0.55),
                                            .init(color: .black.opacity(0.12), location: 1)],
                                    startPoint: .top, endPoint: .bottom)))
    }

    /// Eye placement for the expressions with open eyes; nil for the closed-eyed ones.
    static func openEyes(for face: String) -> (look: CGSize, radius: CGFloat)? {
        switch face {
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
        let shape = figure.body.subtracting(figure.eyeHoles(face: face, look: look, radius: radius, openness: openness))
        let s = min(rect.width, rect.height) / 256 * scale
        return shape.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -128, y: -128))
    }
}

