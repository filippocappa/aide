import AppKit
import ApplicationServices
import SwiftUI

/// Peek (after peek.zone): hold fn ⌥ and Aide's board covers the screen the pointer is on, over any app, full-screen
/// ones too; let go and it's gone. A quick tap keeps it open, to type, answer what's waiting or open a chat; Esc, a
/// click outside the tiles, fn ⌥ again or switching away closes it. Needs Aide on in Privacy & Security →
/// Accessibility (`MacChordWatcher`). On by default, off in Settings → This Mac.
@MainActor
final class MacPeek: ObservableObject {
    static let shared = MacPeek()
    static let enabledKey = "peekShortcut"
    static let shortcut = "fn ⌥"

    enum State { case hidden, held, kept }
    @Published private(set) var state: State = .hidden
    /// Goes up each time the board shows, so it loads again.
    @Published private(set) var showings = 0
    /// The tiles in place: false while the window fades in, so they rise in one after another (`PeekEntrance`).
    @Published private(set) var appeared = false

    private var panel: PeekPanel?
    /// Peek is on but macOS doesn't let Aide see the keys yet (Accessibility).
    @Published private(set) var needsAccess = false
    private var chord: MacChordWatcher?
    private var downAt = Date.distantPast
    /// A press shorter than this is a tap: the board stays.
    private let tapLength: TimeInterval = 0.3

    func start() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        setEnabled(UserDefaults.standard.bool(forKey: Self.enabledKey))
    }

    func setEnabled(_ on: Bool) {
        if on {
            guard chord == nil else { return }
            let chord = MacChordWatcher(pressed: { [weak self] in self?.pressed() },
                                        released: { [weak self] in self?.released() },
                                        interrupted: { [weak self] in self?.interrupted() })
            chord.onAccess = { [weak self] trusted in self?.needsAccess = !trusted }
            chord.start()
            self.chord = chord
        } else {
            chord?.stop()
            chord = nil
            needsAccess = false
            hide()
        }
    }

    /// System Settings → Privacy & Security → Accessibility, where Aide is switched on for Peek.
    func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: The key

    private func pressed() {
        switch state {
        case .hidden:
            downAt = .now
            show()
        case .kept: hide()
        case .held: break // the key repeating
        }
    }

    private func released() {
        guard state == .held else { return }
        if Date.now.timeIntervalSince(downAt) < tapLength { keep() } else { hide() }
    }

    /// fn ⌥ and then another key: a shortcut of its own (fn ⌥ ← and the like), not a peek.
    private func interrupted() {
        if state == .held { hide() }
    }

    // MARK: Showing

    /// Held, then a click or a tap: the board stays and takes the keyboard (without bringing Aide forward, which
    /// would leave a full-screen app's space).
    func keep() {
        guard state != .hidden else { return }
        state = .kept
        panel?.makeKey()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            panel.setFrame(screen.frame, display: false)
        }
        state = .held
        showings += 1
        appeared = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // A beat later, so the tiles are drawn out of place first and then move in.
        DispatchQueue.main.async { [weak self] in
            if self?.state != .hidden { self?.appeared = true }
        }
    }

    func hide() {
        guard state != .hidden else { return }
        state = .hidden
        guard let panel else { return }
        if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
        appeared = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if MacPeek.shared.state == .hidden { panel.orderOut(nil) }
            }
        })
    }

    /// Closes the board and brings Aide's window forward, on a section if one is given.
    func open(_ section: MacSection? = nil) {
        hide()
        MacWindow.show()
        if let section { MacNavigation.shared.section = section }
    }

    private func makePanel() -> PeekPanel {
        let panel = PeekPanel(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onMouseDown = { [weak self] in if self?.state == .held { self?.keep() } }
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.resigned() }

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: MacPeekBoard(peek: self).withAideEnvironment(.shared))
        host.sizingOptions = []
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        return panel
    }

    /// Kept open, then another app or window took the keyboard (⌘Tab, Aide's window): closed, since it would
    /// still cover the screen. A sheet of its own (a draft to edit) doesn't count.
    private func resigned() {
        guard state == .kept else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let panel, state == .kept, !panel.isKeyWindow, panel.attachedSheet == nil,
                  NSApp.keyWindow?.sheetParent !== panel else { return }
            hide()
        }
    }
}

/// The board's window: borderless, over everything, able to take the keyboard without activating Aide.
private final class PeekPanel: NSPanel {
    var onMouseDown: () -> Void = {}
    var onCancel: () -> Void = {}
    var onResignKey: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown() }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

/// Holding fn and ⌥ together, with no other modifier: told when the pair goes down, when either comes up, and when
/// another key is pressed while they're held. Modifier keys alone can't be a hot key, so this watches the modifier
/// keys everywhere, which macOS allows only once Aide is on in Privacy & Security → Accessibility (asked once); a
/// local monitor covers Aide's own windows (the board, kept).
@MainActor
final class MacChordWatcher {
    var onAccess: (Bool) -> Void = { _ in }
    private let pressed: () -> Void
    private let released: () -> Void
    private let interrupted: () -> Void
    private var monitors: [Any] = []
    private var down = false
    private var waitingForAccess: Timer?
    private static let askedKey = "peekAskedAccess"

    init(pressed: @escaping () -> Void, released: @escaping () -> Void, interrupted: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
        self.interrupted = interrupted
    }

    func start() {
        install()
        if AXIsProcessTrusted() { onAccess(true); return }
        onAccess(false)
        if !UserDefaults.standard.bool(forKey: Self.askedKey) {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        // A global monitor made before the permission was given stays deaf: made again once it is.
        waitingForAccess = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.install()
                self?.onAccess(true)
            }
        }
    }

    func stop() {
        waitingForAccess?.invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        down = false
    }

    private func install() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if down { interrupted() }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chord = flags.contains(.function) && flags.contains(.option)
            && flags.isDisjoint(with: [.command, .control, .shift])
        if chord, !down {
            down = true
            pressed()
        } else if !chord, down {
            down = false
            released()
        }
    }
}

// MARK: - The board

/// What Peek shows: the greeting, a box to ask Aide, the week with today's events and reminders, the day at a glance,
/// the team, and what's waiting, answered in place. The menu bar panel's pieces, bigger, in three columns.
struct MacPeekBoard: View {
    @ObservedObject var peek: MacPeek
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var glance = MacGlance.shared
    @ObservedObject private var model = MacPanelModel.shared
    @State private var question = ""
    @FocusState private var asking: Bool

    private var aide: Agent { chat.orchestrator }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.everyMinute) { context in
                ZStack {
                    // A click between or around the tiles closes the board.
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { peek.hide() }
                    VStack(alignment: .leading, spacing: 18) {
                        header(context.date).peekIn(peek.appeared, step: 0)
                        if settings.isConfigured {
                            askBox.peekIn(peek.appeared, step: 1)
                            columns(context.date)
                        } else {
                            tile {
                                Button { peek.open(.settings) } label: {
                                    Label("Set up the server in Settings", systemImage: "gearshape")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(PanelRowStyle())
                            }
                        }
                        footer.peekIn(peek.appeared, step: 5)
                    }
                    .frame(maxWidth: 1240)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 44)
                }
            }
            // Sheets opened from the board (a draft to edit) take their size from it.
            .environment(\.macWindowSize, CGSize(width: min(geo.size.width, 1240), height: min(geo.size.height, 900)))
        }
        .environment(\.colorScheme, .dark)
        .task(id: peek.showings) { await load() }
        .onExitCommand { peek.hide() }
        .onChange(of: peek.state) { _, state in
            if state == .hidden { asking = false }
        }
    }

    // MARK: The pieces

    private func header(_ now: Date) -> some View {
        HStack(spacing: 14) {
            LivePebble(mood: mood(now), size: 52, figure: aide.figure)
                .foregroundStyle(aide.tint)
                .shadow(color: aide.tint.opacity(0.45), radius: 10)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(MacMenuBarPanel.greeting(now))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle(now))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { peek.open() } label: { Label("Open Aide", systemImage: "macwindow") }
                .buttonStyle(PanelRowStyle(fill: .white.opacity(0.08)))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func subtitle(_ now: Date) -> String {
        let date = now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = now.formatted(date: .omitted, time: .shortened)
        let waiting = model.waiting
        return [date, time, waiting == 0 ? nil : waiting == 1 ? "1 thing waiting" : "\(waiting) things waiting"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var askBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(aide.tint)
            TextField("Ask Aide anything…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($asking)
                .onSubmit(ask)
            if !question.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(aide.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color(white: 0.11).opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(asking ? aide.tint.opacity(0.7) : .white.opacity(0.08), lineWidth: 1)
        }
        // Clicking the box while holding the key keeps the board (`PeekPanel`), then it takes the typing.
        .onTapGesture { asking = true }
    }

    private func columns(_ now: Date) -> some View {
        HStack(alignment: .top, spacing: 18) {
            tile {
                MiniCalendar(now: now, model: model, tint: aide.tint, open: { peek.open(.today) })
            }
            .frame(width: 360)
            .peekIn(peek.appeared, step: 2)

            VStack(spacing: 18) {
                tile { MacGlanceCard(glance: glance, open: { peek.open($0) }) }
                tile { team }
            }
            .frame(width: 340)
            .peekIn(peek.appeared, step: 3)

            waiting
                .peekIn(peek.appeared, step: 4)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var waiting: some View {
        if let approvals = model.approvals, approvals.waiting > 0 {
            List {
                WaitingSection(approvals: approvals, agent: nil, reload: { await loadApprovals() }) { openChat($0) }
            }
            .scrollContentBackground(.hidden)
            // As tall as its rows, up to about the other columns' height.
            .frame(height: min(520, CGFloat(approvals.waiting) * 66 + 56))
            .background(Color(white: 0.11).opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
        } else {
            tile {
                VStack(alignment: .leading, spacing: 8) {
                    PanelHeading("Waiting for you")
                    Label(model.approvals == nil ? "Loading…" : "Nothing waiting", systemImage: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var team: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeading("Your team")
            HStack(spacing: 4) {
                ForEach(chat.agents) { agent in
                    Button { openChat(agent.id == "aide" ? "main" : nil, agent: agent) } label: {
                        VStack(spacing: 5) {
                            LivePebble(mood: "awake", size: 38, figure: agent.figure)
                                .foregroundStyle(agent.tint)
                                .allowsHitTesting(false)
                            Text(agent.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelRowStyle(padding: 6))
                    .help("Chat with \(agent.name)")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            ForEach(MacSection.allCases.filter { $0 != .settings && $0 != .team }) { section in
                Button { peek.open(section) } label: { Image(systemName: section.icon) }
                    .buttonStyle(PanelIconStyle())
                    .help(section.title)
            }
            Spacer(minLength: 0)
            Text(peek.state == .kept ? "Esc to close"
                 : "Let go to close · tap \(MacPeek.shortcut) to keep it open")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.07), in: Capsule())
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color(white: 0.11).opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
    }

    // MARK: Doing things

    private func load() async {
        guard settings.isConfigured, peek.state != .hidden else { return }
        async let g: Void = glance.load(env)
        async let t = try? env.api.today()
        async let a: Void = loadApprovals()
        let day = await t
        _ = await (g, a)
        if let day { model.today = day }
    }

    private func loadApprovals() async {
        guard let approvals = try? await env.api.approvals() else { return }
        model.approvals = approvals
        model.waiting = approvals.waiting
    }

    /// A chat in Aide's window: a chat id, "main" (Aide), "team", or an agent's latest.
    private func openChat(_ id: String?, agent: Agent? = nil) {
        peek.open(.team)
        if let agent, id == nil { env.push.route = .agent(agent.id); return }
        switch id {
        case nil: break
        case "team": env.push.route = .team
        case "main": env.push.route = .agent("aide")
        case let id?: env.push.route = .conversation(id)
        }
    }

    /// The question in a new chat with Aide, in the window.
    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        peek.open(.team)
        Task {
            await chat.newChat(with: chat.orchestrator)
            await chat.send(text)
        }
    }

    private func mood(_ now: Date) -> String {
        if chat.isSending { return "thinking" }
        let hour = Calendar.current.component(.hour, from: now)
        return hour < 6 || hour >= 23 ? "sleeping" : "awake"
    }
}

/// A piece of the board coming in: up a little, from slightly smaller and blurred, each piece a moment after the one
/// before. Going out it's one quick fade. Reduce Motion keeps only the fade.
private struct PeekEntrance: ViewModifier {
    let shown: Bool
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = shown || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(still ? 1 : 0.97)
            .offset(y: still ? 0 : 10)
            .blur(radius: still ? 0 : 6)
            .animation(shown ? .spring(duration: 0.3, bounce: 0.12).delay(Double(step) * 0.022)
                             : .easeIn(duration: 0.1),
                       value: shown)
    }
}

private extension View {
    func peekIn(_ shown: Bool, step: Int) -> some View { modifier(PeekEntrance(shown: shown, step: step)) }
}
