import AppKit
import SwiftUI

/// A practice exam opens on the Mac as a window of its own, not as a sheet over Aide's window: macOS won't take a
/// window with a sheet into full screen, so in a sheet neither the green button nor the exam's own did anything.
/// The window opens over Aide's (in full screen when Aide is), and goes away when the exam is quit or finished.
/// On the phone `macWindowCover` is `fullScreenCover` (`Support/Theme.swift`).
@MainActor
final class MacCovers {
    static let shared = MacCovers()

    struct Entry {
        let view: AnyView
        /// Aide's window when it opened: the cover takes its place and its full screen.
        let frame: NSRect?
        let fullScreen: Bool
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

    var body: some View {
        if let id, let entry = MacCovers.shared.entries[id] {
            entry.view
                .environment(\.coverClose) { [box] in
                    if let window = box.window { window.close() } else { dismissWindow(id: MacWindow.cover, value: id) }
                }
                .frame(minWidth: 720, minHeight: 540)
                .background(MacWindowReader { window in
                    box.window = window
                    // The exam has its own ways out (Close, Quit that asks first, Done); the red button and ⌘W
                    // would just drop it.
                    window.standardWindowButton(.closeButton)?.isEnabled = false
                    if let frame = entry.frame { window.setFrame(frame, display: true) }
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
    let cover: () -> AnyView
    @State private var open: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, on in
            if on, open == nil {
                let id = UUID()
                open = id
                let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.title == "Aide" }
                MacCovers.shared.entries[id] = .init(
                    view: cover(), frame: host?.frame, fullScreen: host?.styleMask.contains(.fullScreen) ?? false
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
    func macWindowCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(MacWindowCover(isPresented: isPresented, onDismiss: onDismiss, cover: { AnyView(content()) }))
    }

    func macWindowCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let shown = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return macWindowCover(isPresented: shown, onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
