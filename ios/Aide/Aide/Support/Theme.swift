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

/// The Health scores' rings (docs/API.md, "Scores"): Strain orange, Sleep indigo, Recovery green, amber or red by how
/// recovered. Each is a gradient, start to end of the ring; the same in light and dark.
enum ScoreColors {
    private static func c(_ hex: UInt32) -> Color { Color(uiColor: UIColor(hex: hex)) }
    static let strain = [c(0xFFB340), c(0xFF6A1F)]
    static let sleep = [c(0x8E8CFF), c(0x5E5CE6)]
    static func recovery(_ score: Int?) -> [Color] {
        guard let score else { return [c(0x8E8E93), c(0x8E8E93)] }
        if score >= 67 { return [c(0x5EE07B), c(0x22B04B)] }
        if score >= 34 { return [c(0xFFD84D), c(0xF5A623)] }
        return [c(0xFF7A6B), c(0xE5383B)]
    }
}

extension View {
    /// A soft glow of a colour at the top of the page, on the grouped background: the page's one hue. Nil: none yet
    /// (it fades in when the colour comes).
    func pageGlow(_ color: Color?) -> some View {
        background(alignment: .top) {
            ZStack {
                if let color {
                    LinearGradient(colors: [color.opacity(0.38), color.opacity(0.12), color.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .transition(.opacity)
                }
            }
            .frame(height: 460, alignment: .top)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .animation(.easeInOut(duration: 0.6), value: color == nil)
        }
        .background(Theme.grouped)
    }

    /// Simulator screenshots: `-previewAnchor center` or `bottom` opens a scrolling page further down. Nothing in
    /// release builds.
    @ViewBuilder func previewAnchor() -> some View {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "previewAnchor") {
        case "bottom": defaultScrollAnchor(.bottom)
        case "center": defaultScrollAnchor(.center)
        default: self
        }
        #else
        self
        #endif
    }

    /// Pinned at the bottom with the page scrolling under it, softly faded out where the system can.
    @ViewBuilder func bottomBar<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

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
    /// Inline markdown (bold, italics, links) from the model's replies, keeping line breaks. The vault's
    /// `[[Page]]` and `[[Page|words]]` links (in the notebook's text) read as their words.
    var markdown: AttributedString {
        let text = replacing(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/) { String($0.output.1) }
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - The pages' shared pieces

extension View {
    /// A card on a grouped page: white (dark grey in dark mode), 22 pt round, 16 inside unless rows bring their own.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A titled card: the title above, the content on a card, a note under it. `padding` 0 for rows that bring their own.
struct DetailCard<Content: View>: View {
    let title: String?
    let note: String?
    var padding: CGFloat = 16
    let content: Content

    init(_ title: String? = nil, note: String? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.title3.weight(.bold)).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }.card(padding: padding)
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

/// The top of a page: a small line over a large title, then what the page has to say and its chips.
struct TopBlock<Content: View>: View {
    let overline: String?
    let title: String
    let content: Content

    init(_ title: String, overline: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.overline = overline
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline {
                    Text(overline).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(title).font(.largeTitle.bold())
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

extension TopBlock where Content == EmptyView {
    init(_ title: String, overline: String? = nil) { self.init(title, overline: overline) { EmptyView() } }
}

/// A grey capsule to tap. `prominent` is the page's own colour, for what's waiting for you; `warning` is orange.
struct Chip: View {
    enum Style { case plain, prominent, warning }
    let title: String
    var systemImage: String?
    /// The icon's own colour on a plain chip (a green tick).
    var iconColor: Color?
    var style: Style = .plain
    /// A prominent chip's colour, when the page has its own (Professor's on Study); the app's otherwise.
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(iconColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(CardPress())
    }

    private var foreground: Color {
        switch style {
        case .plain: .primary
        case .prominent: tint == nil ? Theme.onAccent : .white
        case .warning: .white
        }
    }

    private var background: Color {
        switch style {
        case .plain: Theme.chip
        case .prominent: tint ?? Theme.accent
        case .warning: .orange
        }
    }
}

/// One thing that happened, in a card of rows: a mark, what it was, a line of detail and when.
struct StatusRow<Mark: View>: View {
    let title: String
    var detail: String?
    var time: String?
    let mark: Mark

    init(_ title: String, detail: String? = nil, time: String? = nil, @ViewBuilder mark: () -> Mark) {
        self.title = title
        self.detail = detail
        self.time = time
        self.mark = mark()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let time { Text(time).font(.caption).foregroundStyle(.tertiary) }
                }
                if let detail, !detail.isEmpty {
                    Text(detail.markdown).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The hairline between rows in a card, from where the text starts.
struct RowDivider: View {
    var leading: CGFloat = 56
    var body: some View { Divider().padding(.leading, leading) }
}

/// A row in a card: greys a little under the finger.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.chip : Color.clear)
    }
}

/// Cards give a little under the finger, without bouncing back.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
