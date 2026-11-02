import AppKit
import SwiftUI

/// Bigger text on the Mac. The shared views use the text styles (`.body`, `.subheadline`…), which macOS sets at
/// 13 pt and 11 pt (the phone: 17 and 15), too small in a big window. These shadow SwiftUI's styles for `AideMac`
/// only (a declaration in this module wins over the imported one), between the Mac's sizes and the phone's.
/// Text with no font of its own gets `.body` from `MacRootView`.
enum MacFontSize {
    static func of(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 30
        case .title: 25
        case .title2: 20
        case .title3: 17
        case .headline, .body: 15
        case .callout: 14
        case .subheadline: 13
        case .footnote: 12
        case .caption: 11.5
        case .caption2: 10.5
        @unknown default: 15
        }
    }

    static func of(ns style: NSFont.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: of(Font.TextStyle.largeTitle)
        case .title1: of(Font.TextStyle.title)
        case .title2: of(Font.TextStyle.title2)
        case .title3: of(Font.TextStyle.title3)
        case .headline: of(Font.TextStyle.headline)
        case .callout: of(Font.TextStyle.callout)
        case .subheadline: of(Font.TextStyle.subheadline)
        case .footnote: of(Font.TextStyle.footnote)
        case .caption1: of(Font.TextStyle.caption)
        case .caption2: of(Font.TextStyle.caption2)
        default: of(Font.TextStyle.body)
        }
    }
}

extension Font {
    static var largeTitle: Font { .system(size: MacFontSize.of(.largeTitle)) }
    static var title: Font { .system(size: MacFontSize.of(.title)) }
    static var title2: Font { .system(size: MacFontSize.of(.title2)) }
    static var title3: Font { .system(size: MacFontSize.of(.title3)) }
    static var headline: Font { .system(size: MacFontSize.of(.headline), weight: .semibold) }
    static var body: Font { .system(size: MacFontSize.of(.body)) }
    static var callout: Font { .system(size: MacFontSize.of(.callout)) }
    static var subheadline: Font { .system(size: MacFontSize.of(.subheadline)) }
    static var footnote: Font { .system(size: MacFontSize.of(.footnote)) }
    static var caption: Font { .system(size: MacFontSize.of(.caption)) }
    static var caption2: Font { .system(size: MacFontSize.of(.caption2)) }

    static func system(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        .system(size: MacFontSize.of(style), weight: weight ?? (style == .headline ? .semibold : .regular),
                design: design ?? .default)
    }
}

extension NSFont {
    /// `MathText` sizes its formulas from this (`UIFont` is `NSFont` here).
    static func preferredFont(forTextStyle style: NSFont.TextStyle) -> NSFont {
        .systemFont(ofSize: MacFontSize.of(ns: style))
    }
}
