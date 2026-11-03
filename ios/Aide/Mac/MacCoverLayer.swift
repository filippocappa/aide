import AppKit
import SwiftUI

/// What the phone shows over everything with a study item's own ways out (a practice exam, a lesson, the Learn path,
/// a quiz) opens on the Mac as a card over the page, inside Aide's one window: not a sheet, which keeps the window
/// out of full screen (the green button and ⌃⌘F did nothing), and not a window of its own, which piled up one per
/// thing. In full screen the card fills the screen. One opened from a card goes on top of it; closing a card closes
/// what was opened from it. `MacRootView` draws the cards (`MacCoverLayer`); on the phone `macWindowCover` is
/// `fullScreenCover` (`Support/Theme.swift`).
@MainActor
final class MacCoverStack: ObservableObject {
    static let shared = MacCoverStack()

    struct Entry: Identifiable {
        let id: UUID
        let view: AnyView
        let closed: () -> Void
    }

    @Published private(set) var entries: [Entry] = []
    /// The cards fill Aide's window, edge to edge and under the title bar (their ⤢ button); otherwise they sit in it
    /// with a border. Kept for the next card.
    @Published var expanded = UserDefaults.standard.bool(forKey: "macCoverExpanded") {
        didSet { UserDefaults.standard.set(expanded, forKey: "macCoverExpanded") }
    }

    func push(_ entry: Entry) { entries.append(entry) }

    /// Takes the card off, and those opened from it (above it), telling each it's gone.
    func close(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let gone = Array(entries[i...].reversed())
        withAnimation(.snappy(duration: 0.22)) {
            entries.removeSubrange(i...)
        }
        gone.forEach { $0.closed() }
    }
}

/// The cards over Aide's page (`MacRootView`'s top overlay): each dims what's under it, only the top one takes
/// clicks and keys.
struct MacCoverLayer: View {
    let windowSize: CGSize
    @ObservedObject private var stack = MacCoverStack.shared
    @State private var window: NSWindow?
    @State private var fullScreen = false

    /// A card fills the window: the window's title and toolbar (the page's buttons) go, so nothing sits over it.
    private var filling: Bool { stack.expanded && !stack.entries.isEmpty }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(stack.entries) { entry in
                    let top = entry.id == stack.entries.last?.id
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .transition(.opacity)
                    card(entry, in: geo.size)
                        .disabled(!top)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(edges: filling ? .top : [])
        .animation(.snappy(duration: 0.22), value: stack.entries.map(\.id))
        .animation(.snappy(duration: 0.25), value: stack.expanded)
        // With no card up the layer is empty: nothing in it may take a click.
        .allowsHitTesting(!stack.entries.isEmpty)
        .background(MacWindowReader { found in
            window = found
            fullScreen = found.styleMask.contains(.fullScreen)
            showTitleBar(!filling)
        })
        .onChange(of: filling) { _, on in showTitleBar(!on) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = false }
        }
    }

    private func showTitleBar(_ shown: Bool) {
        guard let window else { return }
        window.titleVisibility = shown ? .visible : .hidden
        window.toolbar?.isVisible = shown
    }

    /// The size the sheet had, a little smaller than the window (in full screen too, with its border); expanded, all
    /// of the window under the title bar.
    private func card(_ entry: MacCoverStack.Entry, in space: CGSize) -> some View {
        let full = stack.expanded
        let width = full ? space.width : min(space.width - 24, max(720, space.width - 100))
        let height = full ? space.height : min(space.height - 16, max(540, space.height - 40))
        let shape = RoundedRectangle(cornerRadius: full ? 0 : 16, style: .continuous)
        // Filling a window (not full screen), the card's top row goes below the red, yellow and green buttons.
        let lights: CGFloat = full && !fullScreen ? 28 : 0
        let close = { [stack] in stack.close(entry.id) }
        return entry.view
            .environment(\.coverClose, close)
            .environment(\.macCoverRoot, close)
            .environment(\.macInStack, true)
            .environment(\.macWindowSize, windowSize)
            .font(.body)
            .safeAreaPadding(.top, lights)
            .frame(width: max(width, 0), height: max(height, 0))
            .background(Theme.background)
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(full ? 0 : 0.08)))
            .shadow(color: .black.opacity(full ? 0 : 0.35), radius: 30, y: 12)
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

        /// Only there to find the window: clicks go through to what's under it (over the whole window it took them all).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            found(window)
        }
    }
}

extension EnvironmentValues {
    /// Set on a cover card's own view: its `NavigationStack` (`MacNavigationStack.swift`) gives the close button
    /// this, and the full screen button, then clears it, so a sheet opened inside closes only itself.
    @Entry var macCoverRoot: (() -> Void)? = nil
}

private struct MacWindowCover: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let cover: () -> AnyView
    @State private var open: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, on in
                if on, open == nil {
                    let id = UUID()
                    open = id
                    let entry = MacCoverStack.Entry(id: id, view: cover()) {
                        open = nil
                        if isPresented { isPresented = false }
                        onDismiss?()
                    }
                    withAnimation(.snappy(duration: 0.22)) { MacCoverStack.shared.push(entry) }
                } else if !on, let id = open {
                    MacCoverStack.shared.close(id)
                }
            }
            // The page that opened it went (another section): so does the card, as a sheet would.
            .onDisappear { if let id = open { MacCoverStack.shared.close(id) } }
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
