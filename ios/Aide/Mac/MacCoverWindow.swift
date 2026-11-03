import AppKit
import SwiftUI

/// A practice exam, a lesson, the Learn path or a quiz opens on the Mac as a window of its own, not as a sheet over Aide's window: macOS won't take a
/// window with a sheet into full screen, so in a sheet neither the green button nor the exam's own did anything.
/// The window opens over Aide's, a little smaller like the sheet was (in full screen when Aide is), and goes away when the exam is quit or finished.
/// On the phone `macWindowCover` is `fullScreenCover` (`Support/Theme.swift`).
@MainActor
final class MacCovers {
    static let shared = MacCovers()

    struct Entry {
        let view: AnyView
        /// Aide's window when it opened: the cover opens over it, a little smaller, and in full screen when it is.
        let frame: NSRect?
        let fullScreen: Bool
        /// The red button and ⌘W close it (a lesson, a quiz: saved as they go). Off for an exam, which has its own
        /// ways out, so a click doesn't drop it.
        let closable: Bool
        let closed: () -> Void
    }

    var entries: [UUID: Entry] = [:]
}

extension MacWindow {
    static let cover = "cover"
}

/// What a cover window shows (`AideMacApp`'s `WindowGroup`). A window macOS brings back after a relaunch has no exam
/// any more, so it closes.
struct MacCoverWindowContent: View {
    let id: UUID?
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var box = WindowBox()

    final class WindowBox { weak var window: NSWindow? }

    /// The size the sheet had: a little smaller than Aide's window (`MacSheetSize.cover`), centred across it, its top
    /// just under Aide's title bar. Leaving full screen comes back to this.
    static func popUp(over host: NSRect) -> NSRect {
        let size = MacSheetSize.cover(host.size)
        let width = min(size.width, host.width), height = min(size.height, host.height - 28)
        return NSRect(x: host.midX - width / 2, y: host.maxY - 28 - height, width: width, height: height)
    }

    var body: some View {
        if let id, let entry = MacCovers.shared.entries[id] {
            entry.view
                .environment(\.coverClose) { [box] in
                    if let window = box.window { window.close() } else { dismissWindow(id: MacWindow.cover, value: id) }
                }
                .frame(minWidth: 720, minHeight: 540)
                // Like Aide's window: no title and no band at the top, the traffic lights over the page.
                .modifier(SoftTitleBar())
                .background(MacWindowReader { window in
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    box.window = window
                    // An exam has its own ways out (Close, Quit that asks first, Done); the red button and ⌘W
                    // would just drop it.
                    if !entry.closable { window.standardWindowButton(.closeButton)?.isEnabled = false }
                    // Its own window over Aide's, never a tab beside another.
                    window.tabbingMode = .disallowed
                    if let frame = entry.frame { window.setFrame(Self.popUp(over: frame), display: true) }
                    if entry.fullScreen, !window.styleMask.contains(.fullScreen) {
                        DispatchQueue.main.async { window.toggleFullScreen(nil) }
                    }
                })
                .onDisappear {
                    MacCovers.shared.entries[id] = nil
                    entry.closed()
                }
        } else {
            Color.clear.background(MacWindowReader { $0.close() })
        }
    }
}

/// Hands over the window a view is in, once it's in one.
struct MacWindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let found: (NSWindow) -> Void
        private var done = false

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            found(window)
        }
    }
}

private struct MacWindowCover: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let closable: Bool
    let cover: () -> AnyView
    @State private var open: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Set inside a cover window: one opened from there (the Learn path's lesson, a lesson's quiz) is a sheet in that
    /// window, not a window over it (macOS would put the two in tabs), and closes only itself.
    @Environment(\.coverClose) private var inCover

    @ViewBuilder func body(content: Content) -> some View {
        if inCover != nil {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                cover().macCoverSize().environment(\.coverClose, nil)
            }
        } else {
            windowed(content)
        }
    }

    private func windowed(_ content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, on in
            if on, open == nil {
                let id = UUID()
                open = id
                let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.title == "Aide" }
                MacCovers.shared.entries[id] = .init(
                    view: cover(), frame: host?.frame, fullScreen: host?.styleMask.contains(.fullScreen) ?? false,
                    closable: closable
                ) {
                    open = nil
                    if isPresented { isPresented = false }
                    onDismiss?()
                }
                openWindow(id: MacWindow.cover, value: id)
            } else if !on, let id = open {
                dismissWindow(id: MacWindow.cover, value: id)
            }
        }
    }
}

extension View {
    func macWindowCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, closable: Bool = false,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(MacWindowCover(isPresented: isPresented, onDismiss: onDismiss, closable: closable,
                                cover: { AnyView(content()) }))
    }

    func macWindowCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, closable: Bool = false,
                                                           @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let shown = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return macWindowCover(isPresented: shown, onDismiss: onDismiss, closable: closable) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
