import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Screen Time on the Mac (#30): while a lock holds, the apps it covers can't be used. Aide quits one whenever it
/// opens or comes forward (Dock, Finder, Raycast, ⌘-Tab) and when the lock starts, and Pebble pops up asleep above
/// that app's Dock icon to say so, with Open anyway (a reason and a 10 s wait, or an emergency pass on a strict lock).
/// An app that won't quit (an unsaved document asking) is hidden instead and comes back when the lock ends. It's a
/// commitment device, not a real lock.
@MainActor
final class MacShield {
    private let screenTime: ScreenTimeService
    private let nudge: LockNudge
    /// Apps that didn't quit and were hidden instead, to bring back when they're free (only those: not what the
    /// user hid).
    private var hidden: [pid_t: NSRunningApplication] = [:]
    /// Where each app Aide closed lives, to open it again after Open anyway.
    private var closed: [String: URL] = [:]
    /// The same app opening and coming forward fires twice: one nudge.
    private var lastTry: (bundleID: String, at: Date)?
    private var observers: [NSObjectProtocol] = []
    private var changes: AnyCancellable?

    init(screenTime: ScreenTimeService) {
        self.screenTime = screenTime
        nudge = LockNudge(screenTime: screenTime)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in if let app { self?.tried(app) } }
            })
        }
        // A lock starting or ending, the locks fetched again, the apps picked: look again, after the change has
        // landed (objectWillChange comes before it).
        changes = screenTime.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.check() }
        check()
    }

    private static let me = ProcessInfo.processInfo.processIdentifier

    /// An app opened or came forward: close it if a lock covers it, and say so above its Dock icon.
    private func tried(_ app: NSRunningApplication) {
        guard app.processIdentifier != Self.me, let id = app.bundleIdentifier,
              let hold = screenTime.covering(id) else { return }
        // Before it quits: an app not kept in the Dock has its icon there only while it runs.
        let icon = DockIcon.top(of: app)
        close(app)
        if let lastTry, lastTry.bundleID == id, Date().timeIntervalSince(lastTry.at) < 1.5 { return }
        lastTry = (id, Date())
        nudge.show(app: app.localizedName ?? "This app", bundleID: id, hold: hold, above: icon)
    }

    /// Out of sight at once, then a polite Quit (as from its menu, so it can save). If it's still there a few
    /// seconds later (it's asking about an unsaved document), it stays hidden.
    private func close(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        if let url = app.bundleURL { closed[id] = url }
        app.hide()
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !app.isTerminated, self.screenTime.covering(id) != nil else { return }
            self.hidden[app.processIdentifier] = app
            if !app.isHidden { app.hide() }
        }
    }

    /// Close whatever a lock covers now; bring back what's free again.
    private func check() {
        var first: (app: NSRunningApplication, hold: MacHold, icon: NSPoint?)?
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != Self.me && !app.isTerminated && hidden[app.processIdentifier] == nil {
            guard let hold = screenTime.covering(app.bundleIdentifier) else { continue }
            if first == nil, !app.isHidden { first = (app, hold, DockIcon.top(of: app)) }
            close(app)
        }
        for (pid, app) in hidden where app.isTerminated || screenTime.covering(app.bundleIdentifier) == nil {
            hidden[pid] = nil
            if !app.isTerminated { app.unhide() }
        }
        // Opened anyway: the app comes back.
        if let id = nudge.opening, screenTime.covering(id) == nil {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.unhide()
                app.activate()
            } else if let url = closed[id] {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            nudge.unlocked()
        }
        if let first, let id = first.app.bundleIdentifier {
            nudge.show(app: first.app.localizedName ?? "This app", bundleID: id, hold: first.hold, above: first.icon)
        } else {
            nudge.refresh()
        }
    }
}

/// Where an app's icon is in the Dock, read from the Dock through Accessibility (asked for once, the first time it's
/// needed; without it Pebble stands in the middle of the Dock).
@MainActor
enum DockIcon {
    /// The top centre of the app's Dock icon in screen coordinates (origin bottom left), when the Dock is at the
    /// bottom and the app has an icon there.
    static func top(of app: NSRunningApplication) -> NSPoint? {
        guard trusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let items = children(of: AXUIElementCreateApplication(dock.processIdentifier))
            .filter { string($0, kAXRoleAttribute) == "AXList" }
            .flatMap(children)
        let url = app.bundleURL?.standardizedFileURL
        let item = items.first { item in
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value)
            return (value as? URL)?.standardizedFileURL == url
        } ?? items.first { string($0, kAXTitleAttribute) == app.localizedName }
        guard let item, let frame = frame(of: item) else { return nil }
        // AX measures from the top left of the main screen, AppKit from its bottom left.
        let height = NSScreen.screens.first?.frame.height ?? 0
        let top = NSPoint(x: frame.midX, y: height - frame.minY)
        // A Dock on the side: no "above".
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(NSPoint(x: top.x, y: top.y - 1), $0.frame) }),
              top.y - screen.frame.minY < screen.frame.height / 4 else { return nil }
        return top
    }

    private static var asked = false

    private static func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !asked {
            asked = true
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        return false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}

// MARK: Pebble over the Dock

/// What the nudge shows, shared with its SwiftUI view so it can change without losing the form's state.
@MainActor
private final class LockNudgeModel: ObservableObject {
    @Published var appName = ""
    @Published var bundleID: String?
    @Published var hold: MacHold?
    @Published var shown = false
    @Published var expanded = false
    /// The pointer is on Pebble or the bubble.
    @Published var hovering = false
    /// The pointer is near: Pebble wakes up and leans toward it.
    @Published var near = false
    @Published var lean: CGSize = .zero
    /// Each try: Pebble wakes, shakes its head and dozes off again.
    @Published var pokes = 0
    @Published var startled = false
    @Published var typing = false
    @Published var happy = false
    /// Pebble's distance from the panel's middle, to stand over the icon when the panel meets the screen's edge.
    @Published var shift: CGFloat = 0
    /// Pebble and the bubble, in the panel (SwiftUI's top-left coordinates): where the panel takes the pointer.
    @Published var content: CGRect = .zero

    var mood: String {
        if happy { return "happy" }
        if typing { return "thinking" }
        if startled || near || expanded { return "awake" }
        return "sleeping"
    }
}

/// Pebble asleep, popping up above the app's Dock icon on that screen (or the middle of the Dock on the screen the
/// pointer is on), with a speech bubble: "Calendar's closed until 07:00", Open anyway.
@MainActor
private final class LockNudge {
    private let screenTime: ScreenTimeService
    private let model = LockNudgeModel()
    private var panel: NudgePanel?
    private var leaving: Task<Void, Never>?
    private var dozing: Task<Void, Never>?
    private var pointer: Timer?

    /// The panel never changes size (resizing it with the content looped and crashed): it's transparent, and lets
    /// the pointer through except over Pebble and the bubble.
    private static let size = NSSize(width: 440, height: 380)

    init(screenTime: ScreenTimeService) { self.screenTime = screenTime }

    /// The app being opened anyway: brought back once its lock is gone.
    var opening: String? { model.expanded ? model.bundleID : nil }

    func show(app: String, bundleID: String, hold: MacHold, above icon: NSPoint?) {
        if model.bundleID != bundleID { model.expanded = false; model.typing = false }
        model.appName = app
        model.bundleID = bundleID
        model.hold = hold
        model.happy = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !model.expanded { place(panel, above: icon) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !model.shown {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { model.shown = true }
        }
        followPointer()
        startle()
        leaveLater()
    }

    /// The lock changed: show what holds now, or go once the app is free.
    func refresh() {
        guard model.shown, !model.happy else { return }
        guard let hold = screenTime.covering(model.bundleID) else { return close() }
        model.hold = hold
    }

    /// Unlocked: a happy hop, then back down.
    func unlocked() {
        model.typing = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.expanded = false }
        model.happy = true
        model.pokes += 1
        panel?.resignKey()
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Back down into the Dock.
    func close() {
        leaving?.cancel()
        model.expanded = false
        model.typing = false
        model.hovering = false
        panel?.resignKey()
        withAnimation(.easeIn(duration: 0.25)) { model.shown = false }
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.model.shown else { return }
            self.panel?.orderOut(nil)
            self.pointer?.invalidate()
            self.pointer = nil
            self.model.happy = false
        }
    }

    /// Wakes with a start and shakes its head, then dozes off again.
    private func startle() {
        model.startled = true
        model.pokes += 1
        dozing?.cancel()
        dozing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.model.startled = false
        }
    }

    /// Away by itself after a few seconds, not while the pointer is on it or the form is open.
    private func leaveLater() {
        leaving?.cancel()
        leaving = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled else { return }
                if !self.model.hovering && !self.model.expanded { return self.close() }
            }
        }
    }

    private func expand() {
        leaving?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.expanded = true }
        // The reason field needs the keyboard: the panel takes it without bringing Aide's window forward.
        panel?.makeKeyAndOrderFront(nil)
    }

    private func collapse() {
        model.typing = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.expanded = false }
        panel?.resignKey()
        leaveLater()
    }

    /// 30 times a second while Pebble is up: it wakes when the pointer comes near and leans toward it, and the
    /// panel takes clicks only over Pebble and the bubble.
    private func followPointer() {
        guard pointer == nil else { return }
        pointer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
    }

    private func pointerMoved() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation, frame = panel.frame
        // The content's frame on screen (it's measured from the panel's top left).
        let content = NSRect(x: frame.minX + model.content.minX, y: frame.maxY - model.content.maxY,
                             width: model.content.width, height: model.content.height)
        let over = NSMouseInRect(mouse, content.insetBy(dx: -4, dy: -4), false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if model.hovering != over { model.hovering = over }

        let pebble = NSPoint(x: frame.midX + model.shift, y: frame.minY + 44)
        let dx = mouse.x - pebble.x, dy = mouse.y - pebble.y
        let distance = hypot(dx, dy)
        let near = distance < 260
        if model.near != near { model.near = near }
        // Leans toward the pointer, less the further it is, never past ±1.
        let pull = near ? max(0, 1 - distance / 260) : 0
        let lean = CGSize(width: max(-1, min(1, dx / 120)) * pull, height: max(-1, min(1, -dy / 120)) * pull * 0.6)
        if abs(lean.width - model.lean.width) > 0.02 || abs(lean.height - model.lean.height) > 0.02 { model.lean = lean }
    }

    private func makePanel() -> NudgePanel {
        let panel = NudgePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // Pebble and the bubble draw their own
        panel.ignoresMouseEvents = true
        panel.onEscape = { [weak self] in
            guard let self else { return }
            self.model.expanded ? self.collapse() : self.close()
        }
        let view = NSHostingView(rootView: LockNudgeView(
            model: model, screenTime: screenTime,
            open: { [weak self] in self?.expand() }, keep: { [weak self] in self?.collapse() },
            close: { [weak self] in self?.close() }))
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }

    /// Pebble's feet on the Dock: over the app's icon, else the middle of the Dock on the screen with the pointer
    /// (the visible frame ends where the Dock starts).
    private func place(_ panel: NSPanel, above icon: NSPoint?) {
        let screen = icon.flatMap { icon in NSScreen.screens.first { NSPointInRect(NSPoint(x: icon.x, y: icon.y - 1), $0.frame) } }
            ?? Self.pointerScreen
        guard let area = screen?.visibleFrame else { return }
        let x = icon?.x ?? area.midX
        let bottom = icon.map { max($0.y - 4, area.minY) } ?? area.minY
        let left = min(max(x - Self.size.width / 2, area.minX), area.maxX - Self.size.width)
        model.shift = x - (left + Self.size.width / 2)
        panel.setFrameOrigin(NSPoint(x: left, y: bottom))
    }

    private static var pointerScreen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}

/// A borderless panel that takes the keyboard (the reason field) without activating Aide, and Esc.
private final class NudgePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Pebble on its own with a glass pill above it: "Calendar's asleep till 07:00" and Open anyway. Liquid Glass keeps
/// the words readable on any window, white ones too. Pebble is asleep; startled awake by each try (a shake of the
/// head), awake and leaning toward the pointer when it comes near, thinking while you type a reason, happy when it
/// lets you in. Open anyway (or a click on Pebble) grows the pill into the reason and Unlock after a 10 s wait (a
/// strict lock: an emergency pass, as on the phone). The ×, Esc or a click on Pebble folds it again. Nothing to keep it
/// closed: Pebble goes by itself.
private struct LockNudgeView: View {
    @ObservedObject var model: LockNudgeModel
    @ObservedObject var screenTime: ScreenTimeService
    let open: () -> Void
    let keep: () -> Void
    let close: () -> Void

    @State private var reason = ""
    @State private var left = 10
    @State private var isBusy = false
    @FocusState private var reasonFocused: Bool

    private var hold: MacHold? { model.hold }
    private var isStrict: Bool { hold?.isStrict == true }
    private var noPasses: Bool { isStrict && screenTime.passes?.left == 0 }
    /// The content moves with the icon only as far as the panel lets it; Pebble goes the rest of the way.
    private var slide: CGFloat { max(-20, min(20, model.shift)) }
    private var pebbleX: CGFloat { model.shift - slide }

    var body: some View {
        VStack(spacing: 10) {
            card
                .scaleEffect(model.shown ? 1 : 0.8, anchor: .bottom)
                .opacity(model.shown ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(model.shown ? 0.15 : 0), value: model.shown)
            pebble
        }
        .frame(width: 400)
        .padding(.top, 12)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.content = $0 }
        .offset(x: slide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .tint(Theme.accent)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.happy)
        .onChange(of: reason) { _, new in model.typing = model.expanded && !new.isEmpty }
    }

    private var headline: String {
        if model.happy { return "Go on then" }
        guard let hold = model.hold else { return "\(model.appName)'s asleep" }
        if hold.limit != nil { return "\(model.appName)'s used up for today" }
        return "\(model.appName)'s asleep till \(MacGlanceCard.time(hold.until))"
    }

    private var detail: String? {
        guard let hold, !model.happy else { return nil }
        if noPasses { return "No emergency passes left this month" }
        let title = hold.limit.map { "\($0.title) · \($0.summary), used up" } ?? hold.title
        return hold.agent.map { "\(title) · set by \($0.prefix(1).uppercased() + $0.dropFirst())" } ?? title
    }

    /// Folded: the words and Open anyway on one line. Open: the reason under them, then Unlock.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentTransition(.opacity)
                if !model.expanded && !model.happy && !noPasses && hold != nil {
                    NudgeButton(isStrict ? "Use a pass" : "Open anyway", prominent: true, action: start)
                        .transition(.opacity)
                }
                if model.expanded {
                    Spacer(minLength: 0)
                    Button(action: keep) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Never mind (Esc)")
                    .transition(.opacity)
                }
            }
            // Open, as wide as the form, so the × sits at its right edge.
            .frame(width: model.expanded ? 300 : nil, alignment: .leading)
            if model.expanded, let hold {
                form(hold).transition(.opacity)
            }
        }
        .fixedSize()
        .padding(.leading, 18)
        .padding(.trailing, model.expanded || model.happy || noPasses ? 18 : 6)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .padding(.vertical, model.expanded ? 8 : 0)
        .modifier(StillGlass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // A click anywhere on the pill goes to the reason, not away from it.
        .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .onTapGesture { if model.expanded { reasonFocused = true } }
    }

    private var pebble: some View {
        LivePebble(mood: model.mood, size: 80, lean: model.lean, bounceTrigger: model.pokes)
            .foregroundStyle(Theme.accent)
            .keyframeAnimator(initialValue: 0.0, trigger: model.pokes) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                // A shake of the head: no.
                KeyframeTrack {
                    CubicKeyframe(0, duration: 0.12)
                    CubicKeyframe(-11, duration: 0.09)
                    CubicKeyframe(10, duration: 0.11)
                    CubicKeyframe(-7, duration: 0.11)
                    CubicKeyframe(4, duration: 0.1)
                    CubicKeyframe(0, duration: 0.12)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .contentShape(Circle())
            .onTapGesture { model.expanded ? keep() : start() }
            .offset(x: pebbleX, y: model.shown ? 0 : 130)
    }

    private func start() {
        guard !noPasses, hold != nil else { return }
        reason = ""
        left = 10
        open()
        reasonFocused = true
    }

    private func form(_ hold: MacHold) -> some View {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = left == 0 && !trimmed.isEmpty && !isBusy
        return VStack(alignment: .leading, spacing: 8) {
            TextField(isStrict ? "What's the emergency?" : "Why do you need it now?", text: $reason)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .focused($reasonFocused)
                .onSubmit { if ready { unlock(hold, trimmed) } }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.07), in: Capsule())
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let error = screenTime.lastError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text((isStrict ? "Uses 1 of \(screenTime.passes?.left ?? 0) passes left. " : "")
                             + hold.afterUnlock + " Coach sees why.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView().controlSize(.small).frame(width: 100)
                } else {
                    NudgeButton(left > 0 ? "Unlock in \(left)" : "Unlock", prominent: true, enabled: ready) {
                        unlock(hold, trimmed)
                    }
                }
            }
        }
        .frame(width: 300)
        .task {
            while left > 0 {
                try? await Task.sleep(for: .seconds(1))
                left -= 1
            }
        }
    }

    private func unlock(_ hold: MacHold, _ reason: String) {
        Task {
            isBusy = true
            // Once the lock is gone, MacShield opens the app again and Pebble hops off.
            _ = await screenTime.unlock(hold, reason: reason, pass: isStrict)
            isBusy = false
        }
    }
}

/// Liquid Glass that doesn't react to clicks (the interactive kind flashes and redraws the text field inside), or a
/// frosted material before macOS 26.
private struct StillGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A capsule button in the nudge: plain words, or the accent filled in for the one that goes ahead.
private struct NudgeButton: View {
    let title: String
    var prominent = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, prominent: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(prominent && enabled ? Color.black : .primary)
                .opacity(enabled ? 1 : 0.45)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(prominent && enabled ? AnyShapeStyle(Theme.accent)
                                   : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}
