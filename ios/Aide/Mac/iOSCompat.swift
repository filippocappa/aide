import AppKit
import Security
import SwiftUI

// The shared views are written for the phone. This file lets them build on the Mac without changing them: the UIKit
// types they use stand for their AppKit twins, and the iOS-only modifiers turn into the Mac's nearest (or nothing).
// When a phone change uses something new from UIKit or an iOS-only modifier and the Mac build breaks, add it here, or
// wrap that bit in `#if os(iOS)` when there's no sensible Mac meaning.

// MARK: - Colours, fonts, images

typealias UIColor = NSColor
typealias UIFont = NSFont
typealias UIImage = NSImage

enum UIUserInterfaceStyle { case unspecified, light, dark }

struct UITraitCollection {
    var userInterfaceStyle: UIUserInterfaceStyle = .unspecified

    init(userInterfaceStyle: UIUserInterfaceStyle) { self.userInterfaceStyle = userInterfaceStyle }

    init(_ appearance: NSAppearance) {
        userInterfaceStyle = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

extension NSColor {
    /// `UIColor { traits in … }`: a colour that follows light and dark mode.
    convenience init(_ provider: @escaping (UITraitCollection) -> NSColor) {
        self.init(name: nil) { provider(UITraitCollection($0)) }
    }

    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var systemBackground: NSColor { .windowBackgroundColor }

    func resolvedColor(with traits: UITraitCollection) -> NSColor {
        let name: NSAppearance.Name = traits.userInterfaceStyle == .dark ? .darkAqua : .aqua
        var resolved = self
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    /// Points and pixels are the same here: images come from data, not from a screen of a given scale.
    var scale: CGFloat { 1 }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// UIKit decodes ahead of drawing; AppKit decodes when it draws.
    func preparingForDisplay() -> NSImage? { self }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

// MARK: - The app, the device, the clipboard, haptics

@MainActor
final class UIApplication {
    static let shared = UIApplication()
    static let openSettingsURLString = "x-apple.systempreferences:"
    /// The Mac doesn't lock on a timer the app can hold off; nothing to do.
    var isIdleTimerDisabled = false
    /// Only a build signed for push asks APNs (Mac/AideMacPush.entitlements); without it there's no token to get.
    func registerForRemoteNotifications() {
        if Self.canPush { NSApplication.shared.registerForRemoteNotifications() }
    }

    static let canPush: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) != nil
    }()
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

@MainActor
struct UIDevice {
    static let current = UIDevice()
    var name: String { Host.current().localizedName ?? "Mac" }
}

final class UIPasteboard {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

struct UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle) {}
    func impactOccurred() {}
    func prepare() {}
}

struct UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    func notificationOccurred(_ type: FeedbackType) {}
    func prepare() {}
}

struct UISelectionFeedbackGenerator {
    func selectionChanged() {}
    func prepare() {}
}

// MARK: - Views from UIKit

/// A `UIViewRepresentable` written for the phone, drawn with the same code here: the views it makes (PDFKit's
/// `PDFView`, SwiftMath's label) exist on both.
protocol UIViewRepresentable: NSViewRepresentable where NSViewType == UIViewType {
    associatedtype UIViewType: NSView
    @MainActor func makeUIView(context: Context) -> UIViewType
    @MainActor func updateUIView(_ uiView: UIViewType, context: Context)
    @MainActor func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIViewType, context: Context) -> CGSize?
}

extension UIViewRepresentable {
    @MainActor func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    @MainActor func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
    @MainActor func sizeThatFits(_ proposal: ProposedViewSize, nsView: UIViewType, context: Context) -> CGSize? {
        sizeThatFits(proposal, uiView: nsView, context: context)
    }
    @MainActor func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIViewType, context: Context) -> CGSize? { nil }
}

// MARK: - iOS-only modifiers

enum MacTitleDisplayMode { case automatic, inline, large }

enum UIKeyboardType { case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad,
                      emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad }

enum MacAutocapitalization { case never, words, sentences, characters }

extension View {
    /// Mac windows have one title style.
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }

    /// Mac keyboards have every key.
    func keyboardType(_ type: UIKeyboardType) -> some View { self }

    func textInputAutocapitalization(_ style: MacAutocapitalization?) -> some View { self }

    /// The phone's full-screen pages come up as sheets.
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().macCoverSize() }
    }

    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).macCoverSize() }
    }

    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    /// What the phone shows over everything (slides, a practice exam, a photo) opens as a large sheet: the most of
    /// the window a sheet can take.
    func macCoverSize() -> some View {
        modifier(MacCoverFrame()).macSheet()
    }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var bottomBar: ToolbarItemPlacement { .automatic }
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
}

/// The phone's navigation and tab bars, which the Mac doesn't have. The window toolbar stays whatever a page asks:
/// hiding it takes the traffic lights with it.
enum MacPhoneBar { case navigationBar, tabBar }

extension View {
    /// A page that hides the phone's navigation bar draws its own header, with its own back button (a chat), so the
    /// window's back button goes. Nothing else changes.
    @ViewBuilder func toolbar(_ visibility: Visibility, for bar: MacPhoneBar) -> some View {
        if visibility == .hidden, bar == .navigationBar { navigationBarBackButtonHidden(true) } else { self }
    }

    func toolbarBackground(_ visibility: Visibility, for bar: MacPhoneBar) -> some View { self }
}

enum MacSectionSpacing { case `default`, compact }

enum MacDrawerDisplayMode { case automatic, always }

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: MacDrawerDisplayMode = .automatic) -> SearchFieldPlacement { .automatic }
    static var navigationBarDrawer: SearchFieldPlacement { .automatic }
}

extension View {
    func listSectionSpacing(_ spacing: MacSectionSpacing) -> some View { self }
    func listSectionSpacing(_ spacing: CGFloat) -> some View { self }
}

/// Lists reorder by dragging on the Mac, with no edit mode to switch on.
struct EditButton: View {
    var body: some View { EmptyView() }
}

/// The Shortcuts app's link button is the phone's.
struct ShortcutsLink: View {
    var body: some View { EmptyView() }
}

/// The phone's switch row: the label on the left and the switch at the end of the row. The Mac's `.switch` puts the
/// switch right after its label, which in a card leaves it in the middle.
struct MacSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == MacSwitchStyle {
    static var phoneSwitch: MacSwitchStyle { MacSwitchStyle() }
}
