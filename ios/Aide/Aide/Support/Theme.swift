import SwiftUI
import UIKit

/// Pebble's palette: Slate #34413F and Sand #ECE5D8 (brand/README.md) for ink and buttons, on plain white or
/// black. The pages stay neutral so the only colour on screen is the agents' figures.
enum Theme {
    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let slate = Color(uiColor: UIColor(hex: 0x34413F))
    static let sand = Color(uiColor: UIColor(hex: 0xECE5D8))

    static let background = color(light: 0xFFFFFF, dark: 0x000000)
    static let card = color(light: 0xF4F4F3, dark: 0x1C1C1E)
    static let accent = color(light: 0x34413F, dark: 0xECE5D8)
    static let onAccent = color(light: 0xECE5D8, dark: 0x34413F)
    static let userBubble = color(light: 0xF0F0EF, dark: 0x262628)
    static let chip = color(light: 0xEBEBEA, dark: 0x2C2C2E)
    /// Lists and forms: the system's grouped look, white rows on light grey (dark rows on black).
    static let grouped = color(light: 0xF2F2F7, dark: 0x000000)
    static let row = color(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// Hairline around the message box.
    static let line = color(light: 0xE4E4E2, dark: 0x2C2C2E)
    private static let palette: [Color] = [
        Color(red: 0.24, green: 0.49, blue: 0.69), // ocean
        Color(red: 0.42, green: 0.56, blue: 0.44), // sage
        Color(red: 0.56, green: 0.35, blue: 0.61), // plum
        Color(red: 0.85, green: 0.64, blue: 0.25), // amber
        Color(red: 0.78, green: 0.36, blue: 0.48), // rose
        Color(red: 0.16, green: 0.62, blue: 0.56), // teal
    ]

    /// A stable colour per name (calendar, event title), the same on every launch.
    static func tint(for key: String) -> Color {
        var h: UInt32 = 5381
        for u in key.lowercased().unicodeScalars { h = h &* 33 &+ u.value }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// A colour from the server (`#RRGGBB`), lightened a little in dark mode so a dark one stays readable on black.
    static func readable(_ hex: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let base = UIColor(hex: hex)
            guard traits.userInterfaceStyle == .dark else { return base }
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UIColor(red: r + (1 - r) * 0.3, green: g + (1 - g) * 0.3, blue: b + (1 - b) * 0.3, alpha: a)
        })
    }

    /// Switch colour: Sand-on-white switches vanish in dark mode, so switches get a sage green.
    static let toggle = Color(red: 0.15, green: 0.68, blue: 0.36)
    /// Soft halo behind Pebble.
    static let glow = color(light: 0x5FA88A, dark: 0xECE5D8)
    static let userBubbleText = color(light: 0x111111, dark: 0xF2F2F2)
}

extension View {
    /// A floating control: Liquid Glass where the system has it, else a frosted material with a soft shadow.
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape).shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Agent {
    /// Pebble's colour for this agent. Aide keeps the app's own Slate and Sand; the others lighten a little
    /// in dark mode so they stay readable on the dark background.
    var tint: Color {
        guard !orchestrator, let hex else { return Theme.accent }
        return Theme.readable(hex)
    }
}

extension CalendarEvent {
    /// Its calendar's own colour, as in the Calendar app; a stable one from the calendar's name when iCloud gave none.
    var tint: Color {
        if let color, color.hasPrefix("#"), let hex = UInt32(color.dropFirst(), radix: 16) { return Theme.readable(hex) }
        return Theme.tint(for: calendar ?? title)
    }
}

/// Pebble (or one of its family) at rest, still, tinted by the surrounding foreground style.
struct PebbleMark: View {
    var size: CGFloat = 28
    var figure: Figure = .pebble
    var body: some View {
        FigureShape(figure: figure, face: "calm", scale: 1)
            .shaded()
            .frame(width: size, height: size)
    }
}

/// An agent's figure in its colour, still.
struct AgentMark: View {
    let agent: Agent
    var size: CGFloat = 28
    var body: some View {
        PebbleMark(size: size, figure: agent.figure).foregroundStyle(agent.tint)
    }
}

extension Agent {
    var figure: Figure { Figure(agent: id) }
}

extension String {
    /// Inline markdown (bold, italics, links) from the model's replies, keeping line breaks.
    var markdown: AttributedString {
        (try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(self)
    }
}
