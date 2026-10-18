import SwiftUI
import UIKit

/// Pebble's palette: Slate #34413F and Sand #ECE5D8 (brand/README.md), with dark-mode counterparts.
enum Theme {
    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let slate = Color(uiColor: UIColor(hex: 0x34413F))
    static let sand = Color(uiColor: UIColor(hex: 0xECE5D8))

    static let background = color(light: 0xF5F1E9, dark: 0x1A2120)
    static let card = color(light: 0xFFFFFF, dark: 0x252E2C)
    static let accent = color(light: 0x34413F, dark: 0xECE5D8)
    static let onAccent = color(light: 0xECE5D8, dark: 0x34413F)
    static let userBubble = color(light: 0x34413F, dark: 0x3B4A47)
    static let chip = color(light: 0xE8E1D2, dark: 0x2B3634)
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

    /// Switch colour: Sand-on-white switches vanish in dark mode, so switches get a sage green.
    static let toggle = Color(red: 0.15, green: 0.68, blue: 0.36)
    /// Soft halo behind Pebble.
    static let glow = color(light: 0x5FA88A, dark: 0xECE5D8)
    static let userBubbleText = Color(uiColor: UIColor(hex: 0xECE5D8))
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

/// Pebble from the asset catalog, tinted by the surrounding foreground style.
struct PebbleMark: View {
    var size: CGFloat = 28
    var body: some View {
        Image("Pebble")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

extension String {
    /// Inline markdown (bold, italics, links) from the model's replies, keeping line breaks.
    var markdown: AttributedString {
        (try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(self)
    }
}
