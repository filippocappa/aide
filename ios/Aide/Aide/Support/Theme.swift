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
