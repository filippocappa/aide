import SwiftUI

/// On the phone a sheet goes away with a swipe down, so many have no Close or Done of their own; on the Mac that
/// leaves only Esc, which nobody sees. In the Mac app `NavigationStack` is this: the same stack, and when it's a
/// sheet's, a close button in its top-left corner (where iOS 26 puts its own). The shared views keep writing
/// `NavigationStack`; `SwiftUI.NavigationStack` is still there by its full name.
///
/// A stack is a sheet's when it sits inside another stack (the sheet carries the environment of the page that opened
/// it), or when `MacRootView` says so for the sheets it opens itself. `isPresented` can't tell: the window's own
/// pages count as presented too.
struct NavigationStack<Root: View>: View {
    private let stack: AnyView
    @Environment(\.macInStack) private var inSheet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macWindowSize) private var window

    init(@ViewBuilder root: () -> Root) {
        stack = AnyView(SwiftUI.NavigationStack(root: root))
    }

    init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        stack = AnyView(SwiftUI.NavigationStack(path: path, root: root))
    }

    init<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection>(
        path: Binding<Data>, @ViewBuilder root: () -> Root
    ) where Data.Element: Hashable {
        stack = AnyView(SwiftUI.NavigationStack(path: path, root: root))
    }

    @State private var title: String?
    @State private var hidesClose = false

    var body: some View {
        if inSheet {
            stack
                .environment(\.macInStack, true)
                .toggleStyle(.phoneSwitch)
                .formStyle(.grouped)
                .onPreferenceChange(MacSheetTitleKey.self) { title = $0 }
                .onPreferenceChange(MacSheetHidesCloseKey.self) { hidesClose = $0 }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !hidesClose { closeRow }
                }
                // Phone sheets fill the screen; on the Mac a sheet comes up at its smallest size. Most of the window.
                .frame(minWidth: MacSheetSize.sheet(window).width, maxWidth: .infinity,
                       minHeight: MacSheetSize.sheet(window).height, maxHeight: .infinity)
        } else {
            stack.environment(\.macInStack, true)
        }
    }

    private var closeRow: some View {
        HStack {
            SheetCloseButton { dismiss() }
            Spacer()
        }
        .overlay {
            if let title { Text(title).font(.headline).lineLimit(1).padding(.horizontal, 56) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// A sheet's title, in the middle of the row with the close button (the Mac shows no navigation title in a sheet).
struct MacSheetTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
}

/// A page in a sheet that has its own way out (a practice exam's Quit, which asks first) hides the close button.
struct MacSheetHidesCloseKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension EnvironmentValues {
    @Entry var macInStack = false
    /// The main window's size (`MacRootView`); sheets carry it from the page that opened them.
    @Entry var macWindowSize = CGSize(width: 1180, height: 780)
}

/// How big a sheet comes up. macOS opens a sheet at its minimum size (an ideal size is ignored), so the minimum is
/// worked out from the window: a sheet most of it, a cover (slides, a video) nearly all of it.
enum MacSheetSize {
    static func sheet(_ window: CGSize) -> CGSize {
        CGSize(width: min(max(620, window.width * 0.66), 860), height: max(520, window.height - 120))
    }

    static func cover(_ window: CGSize) -> CGSize {
        CGSize(width: max(720, window.width - 100), height: max(540, window.height - 70))
    }
}

/// A cover's size, from the window.
struct MacCoverFrame: ViewModifier {
    @Environment(\.macWindowSize) private var window

    func body(content: Content) -> some View {
        content.frame(minWidth: MacSheetSize.cover(window).width, maxWidth: .infinity,
                      minHeight: MacSheetSize.cover(window).height, maxHeight: .infinity)
    }
}

extension View {
    /// For a sheet whose stack isn't inside another: give it the close button.
    func macSheet() -> some View { environment(\.macInStack, true) }

    /// For the sheets `MacRootView` opens itself, outside the page that carries the window's size: the close button
    /// and the size from the window. No frame of their own around it: a sheet takes its outermost minimum, and a
    /// smaller one there left the stack wider than its sheet, cut off on both sides.
    func macSheet(_ window: CGSize) -> some View {
        environment(\.macInStack, true).environment(\.macWindowSize, window)
    }

    /// The title shown next to a sheet's close button.
    func macSheetTitle(_ title: String) -> some View { preference(key: MacSheetTitleKey.self, value: title) }

    /// No close button on this sheet: the page has its own way out.
    func macSheetHidesClose() -> some View { preference(key: MacSheetHidesCloseKey.self, value: true) }
}

private struct SheetCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(CloseBackground())
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

private struct CloseBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

/// The window in and out of full screen (⌃⌘F), from a sheet too: the sheet's window is the main one's child, and a
/// cover grows with it (`MacSheetSize.cover`).
struct MacFullScreenButton: View {
    @State private var full = MacFullScreenButton.window?.styleMask.contains(.fullScreen) ?? false

    var body: some View {
        Button {
            MacFullScreenButton.window?.toggleFullScreen(nil)
        } label: {
            Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(CloseBackground())
        .keyboardShortcut("f", modifiers: [.control, .command])
        .help(full ? "Exit Full Screen (⌃⌘F)" : "Full Screen (⌃⌘F)")
        .accessibilityLabel(full ? "Exit full screen" : "Full screen")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in full = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in full = false }
    }

    /// Aide's window: the one the sheet hangs from, else the main one.
    private static var window: NSWindow? {
        let key = NSApp.keyWindow
        return key?.sheetParent ?? NSApp.mainWindow ?? key
    }
}
