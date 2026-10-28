import SwiftUI

// Browser errands (docs/API.md, "Browser errands"): Aide doing something on a website in its own browser on the
// server. The card in chat, the live view where you log in or watch, the order to confirm, and Settings → Browser.

/// What the live view shows: an errand's page, or a site opened to log in to.
enum BrowserTarget: Identifiable, Hashable {
    case errand(Int, title: String)
    case site(String)

    var id: String {
        switch self {
        case .errand(let id, _): "errand:\(id)"
        case .site(let site): "site:\(site)"
        }
    }
}

// MARK: - The live view

/// The live view's socket: the page's frames in, your taps and typing out. What you type goes straight to the page;
/// it's never kept here or on the server, and the model never sees it.
@MainActor
final class BrowserLive: ObservableObject {
    struct Status: Decodable, Equatable {
        let status: String
        var step: String?
        let control: Bool
        var reason: String?
        var url: String?
    }

    /// The focused field on the page: password, username, code, phone, number, text, or nil (none).
    struct Focus: Equatable {
        var field: String?
        var label: String?
    }

    /// What Aide just did on the page: where (the element's middle, 0–1 across the visible page) and on what.
    struct Action: Decodable, Equatable {
        let seq: Int
        /// open, click, type, choose, press, scroll, back, read, find, look
        let kind: String
        var x: Double?
        var y: Double?
        var label: String?
        /// Aide's own line for it ("Guardo le recensioni"), when it gave one.
        var note: String?

        var line: String {
            let quoted = label.map { "“\($0)”" }
            switch kind {
            case "click": return quoted.map { "Tapping \($0)" } ?? "Tapping"
            case "type": return quoted.map { "Typing \($0)" } ?? "Typing"
            case "choose": return quoted.map { "Choosing \($0)" } ?? "Choosing"
            case "open": return "Opening \(label ?? "a page")"
            case "scroll": return label == "up" ? "Scrolling up" : "Scrolling down"
            case "back": return "Going back"
            case "press": return "Pressing \(label ?? "a key")"
            case "read": return "Reading the page"
            case "find": return quoted.map { "Looking for \($0)" } ?? "Looking"
            case "look": return "Looking at the page"
            default: return label ?? kind
            }
        }

        var point: CGPoint? { x.flatMap { x in y.map { CGPoint(x: x, y: $0) } } }
        /// What to say under the stage: Aide's words, else what it did.
        var said: String { note ?? line }
        var addsToCart: Bool {
            kind == "click" && (label ?? "").range(of: #"aggiungi|carrello|add to|cart|basket|bag|warenkorb|panier|increase quantity|aumenta|^\+"#,
                                                  options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The CAPTCHA's picture and where it is on the page (fractions of the frame).
    struct Crop: Equatable {
        let image: UIImage
        let box: CGRect

        /// A tap at (u, v) across the picture (0–1), as a point on the page.
        func pagePoint(u: Double, v: Double) -> CGPoint {
            CGPoint(x: box.minX + u * box.width, y: box.minY + v * box.height)
        }
    }

    @Published private(set) var frame: UIImage?
    @Published private(set) var status: Status?
    @Published private(set) var focus = Focus()
    @Published private(set) var action: Action?
    @Published private(set) var scene: PageScene?
    @Published private(set) var crop: Crop?
    /// Why the socket closed, when it did on its own.
    @Published private(set) var closed: String?

    private var task: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?

    var control: Bool { status?.control ?? false }
    /// Open and not closed by the server.
    var connected: Bool { task != nil && closed == nil }

    func connect(_ request: URLRequest) {
        disconnect()
        closed = nil
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        reader = Task { [weak self] in await self?.read(task) }
    }

    func disconnect() {
        reader?.cancel()
        reader = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func tap(x: Double, y: Double) { send(["type": "tap", "x": x, "y": y]) }
    func scroll(x: Double, y: Double, dy: Double) { send(["type": "scroll", "x": x, "y": y, "dy": dy]) }
    func type(_ text: String) { send(["type": "text", "text": text]) }
    func key(_ name: String) { send(["type": "key", "key": name]) }
    /// Your text into one of the scene's fields (the app's own login screen). Straight to the page, never kept.
    func fill(ref: String, text: String) { send(["type": "fill", "ref": ref, "text": text]) }
    func press(ref: String) { send(["type": "press", "ref": ref]) }
    /// The page's frames on ("Show the real page") or off.
    func frames(on: Bool) { send(["type": "frames", "on": on]) }

    /// You're done: the errand goes on (or the login page closes). Waits for the server to take it.
    func done() async {
        guard let task else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "done"]),
           let text = String(data: data, encoding: .utf8) {
            try? await task.send(.string(text))
        }
        try? await Task.sleep(for: .milliseconds(400))
        disconnect()
    }

    private func send(_ message: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func read(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard !Task.isCancelled else { return }
                closed = task.closeCode == .policyViolation ? "The server didn't open this page."
                    : "The live view closed."
                return
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            // A frame is a JPEG of a few hundred KB: decoded off the main thread.
            let parsed = await Task.detached(priority: .userInitiated) { Self.parse(data) }.value
            switch parsed {
            case .frame(let image): frame = image
            case .status(let s): status = s
            case .focus(let f): focus = f
            case .action(let a): action = a
            case .scene(let s): scene = s
            case .crop(let c): crop = c
            case nil: break
            }
        }
    }

    private enum Incoming: @unchecked Sendable {
        case frame(UIImage), status(Status), focus(Focus), action(Action), scene(PageScene), crop(Crop)
    }

    nonisolated private static func parse(_ data: Data) -> Incoming? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "frame":
            guard let b64 = object["data"] as? String, let jpeg = Data(base64Encoded: b64),
                  let image = UIImage(data: jpeg) else { return nil }
            return .frame(image.preparingForDisplay() ?? image)
        case "status":
            return (try? JSONDecoder.api.decode(Status.self, from: data)).map(Incoming.status)
        case "focus":
            return .focus(Focus(field: object["field"] as? String, label: object["label"] as? String))
        case "action":
            return (try? JSONDecoder.api.decode(Action.self, from: data)).map(Incoming.action)
        case "scene":
            return (try? JSONDecoder.api.decode(PageScene.self, from: data)).map(Incoming.scene)
        case "crop":
            guard let b64 = object["data"] as? String, let jpeg = Data(base64Encoded: b64),
                  let image = UIImage(data: jpeg), let box = object["box"] as? [String: Double] else { return nil }
            return .crop(Crop(image: image, box: CGRect(x: box["x"] ?? 0, y: box["y"] ?? 0,
                                                        width: box["width"] ?? 1, height: box["height"] ?? 1)))
        default:
            return nil
        }
    }
}

/// The page in Aide's browser, live: tap and drag on it as on any page, and type in the bar below, which follows
/// the field the page has focused (a password field is a secure one, so the phone offers its saved passwords and
/// codes). While Aide is working the view only watches.
struct BrowserSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let target: BrowserTarget
    /// After "I'm done" or closing, to load the errand again.
    var onClose: () -> Void = {}

    @StateObject private var live = BrowserLive()
    @State private var typed = ""
    @State private var finishing = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                page
                if live.control, let field = live.focus.field {
                    inputBar(field)
                }
                controls
            }
            .background(Theme.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
            }
        }
        .task { connect() }
        .onDisappear { live.disconnect() }
        .onChange(of: live.focus) { _, _ in typed = "" }
    }

    private var title: String {
        switch target {
        case .errand(_, let title): title
        case .site(let site): site
        }
    }

    private var isLogin: Bool { if case .site = target { true } else { false } }

    @ViewBuilder
    private var banner: some View {
        if let closed = live.closed {
            HStack {
                Label(closed, systemImage: "wifi.exclamationmark").font(.footnote)
                Spacer()
                Button("Try again") { connect() }.font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.orange.opacity(0.15))
        } else if let status = live.status {
            let text = status.control ? (status.reason ?? (isLogin ? "Log in as you would on your phone. Aide never sees what you type." : "Your turn: do what the page needs, then tap I'm done."))
                : "Aide is working: \(live.action?.line ?? status.step ?? "on it"). You're watching."
            Label(text, systemImage: status.control ? "hand.point.up.left.fill" : "eye")
                .font(.footnote)
                .foregroundStyle(status.control ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.row)
        }
    }

    private var page: some View {
        ZStack {
            if let frame = live.frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                                    touch(value, in: geo.size)
                                })
                            if !live.control, let action = live.action, let point = action.point {
                                TapMark(tint: Theme.glow)
                                    .id(action.seq)
                                    .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !live.control && live.closed == nil {
                            Label("Watching", systemImage: "eye.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 12)
                        }
                    }
            } else if live.closed == nil {
                ProgressView("Opening the page…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// A tap where the finger lifted without moving; else a scroll by how far it went.
    private func touch(_ value: DragGesture.Value, in size: CGSize) {
        guard live.control, size.width > 0, size.height > 0 else { return }
        let start = value.startLocation, moved = value.translation
        let x = start.x / size.width, y = start.y / size.height
        if hypot(moved.width, moved.height) < 8 {
            typing = false
            live.tap(x: x, y: y)
        } else {
            live.scroll(x: x, y: y, dy: -moved.height / size.height)
        }
    }

    private func inputBar(_ field: String) -> some View {
        HStack(spacing: 10) {
            PageField(kind: field, label: live.focus.label, text: $typed)
            .focused($typing)
            .submitLabel(.send)
            .onSubmit(sendTyped)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(typed.isEmpty)
            .accessibilityLabel("Type it into the page")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.row)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { live.key("Back") } label: { Image(systemName: "chevron.backward").frame(width: 28) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Back")
            Button { live.key("Tab") } label: { Image(systemName: "arrow.right.to.line").frame(width: 28) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Next field")
            Button { live.key("Enter") } label: { Image(systemName: "return").frame(width: 28) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Enter")
            Button {
                Task { await finish() }
            } label: {
                Group {
                    if finishing { ProgressView() } else { Text(isLogin ? "Done" : "I'm done") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .disabled(finishing)
        }
        .disabled(!live.control && !isLogin)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.row)
    }

    private func sendTyped() {
        guard !typed.isEmpty else { return }
        live.type(typed)
        typed = ""
    }

    private func connect() {
        let request: URLRequest?
        switch target {
        case .errand(let id, _): request = try? env.api.browserLiveRequest(errand: id)
        case .site(let site): request = try? env.api.browserLiveRequest(site: site)
        }
        if let request { live.connect(request) }
    }

    private func finish() async {
        finishing = true
        await live.done()
        finishing = false
        onClose()
        dismiss()
    }

    private func close() {
        live.disconnect()
        onClose()
        dismiss()
    }
}

// MARK: - In chat

/// An errand's card under Aide's message: where it is, and what you can do now (take over, answer, confirm,
/// watch, cancel). It keeps itself up to date while the errand is going.
struct ErrandCard: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.scenePhase) private var phase
    @State private var errand: Errand
    @State private var browser: BrowserTarget?
    /// The real page (the card's menu): for what Aide's own screens don't cover.
    @State private var realPage: BrowserTarget?
    @State private var confirming: QueuedAction?
    @State private var busy = false
    @State private var error: String?

    init(errand: Errand) { _errand = State(initialValue: errand) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ErrandIcon(errand: errand, tint: chat.agent("aide").tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(errand.title).font(.headline).lineLimit(2)
                    Text("\(errand.siteName) · \(Self.state(errand))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !errand.isOver {
                Text(errand.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            if ErrandLiveBox.shows(errand) {
                ErrandLiveBox(errand: errand, tint: chat.agent("aide").tint) {
                    browser = .errand(errand.id, title: errand.title)
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                        removal: .opacity))
            }
            ErrandButtons(errand: errand, busy: busy,
                          takeOver: { browser = .errand(errand.id, title: errand.title) },
                          answer: { answer in Task { await act { try await env.api.replyErrand(errand.id, answer: answer) } } },
                          review: { Task { await review() } },
                          cancel: { Task { await act { try await env.api.cancelErrand(errand.id) } } })
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.spring(duration: 0.45), value: ErrandLiveBox.shows(errand))
        .task(id: errand.id) { await follow() }
        .contextMenu {
            if ErrandLiveBox.shows(errand) {
                Button("Show the real page", systemImage: "safari") {
                    realPage = .errand(errand.id, title: errand.title)
                }
            }
        }
        .sheet(item: $browser) { target in
            StageSheet(target: target, tint: chat.agent("aide").tint) { Task { await refresh() } }
        }
        .fullScreenCover(item: $realPage) { target in
            BrowserSheet(target: target) { Task { await refresh() } }
        }
        .sheet(item: $confirming) { action in
            PurchaseConfirmSheet(action: action) { await refresh() }
        }
    }

    static func state(_ e: Errand) -> String {
        switch e.status {
        case "queued": "Waiting to start"
        case "running": "Working"
        case "needs_you": e.needsAnswer ? "Asks you" : "Needs you"
        case "waiting_confirm": "Waiting for your Confirm"
        case "done": "Done"
        case "failed": "Couldn't finish"
        case "cancelled": "Cancelled"
        case "interrupted": "Stopped"
        default: e.status
        }
    }

    /// Loads it every few seconds while it's going and on screen; a change may have come with a message.
    private func follow() async {
        await refresh()
        while !Task.isCancelled && !errand.isOver {
            try? await Task.sleep(for: .seconds(errand.isWorking ? 4 : 15))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        guard let fresh = try? await env.api.errand(errand.id) else { return }
        let changed = fresh.status != errand.status
        // It just reached a login, a code or a CAPTCHA while you're watching: its screen opens by itself (the app's
        // one sheet, so two cards for the same errand open it once).
        if !errand.needsLiveView, Self.opensByItself(fresh), phase == .active, browser == nil, env.browser == nil {
            env.browser = .errand(fresh.id, title: fresh.title)
        }
        errand = fresh
        if changed, let id = fresh.conversationId, id == chat.conversationID { await chat.loadHistory() }
    }

    static func opensByItself(_ e: Errand) -> Bool {
        e.needsLiveView && ["login", "code", "captcha"].contains(e.why ?? "")
    }

    private func act(_ call: () async throws -> Errand) async {
        busy = true
        defer { busy = false }
        do { errand = try await call(); error = nil } catch { self.error = error.localizedDescription }
    }

    /// The order waiting for your Confirm, from the queue.
    private func review() async {
        busy = true
        defer { busy = false }
        do {
            let approvals = try await env.api.approvals()
            if let action = approvals.actions.first(where: { $0.id == errand.actionId }) {
                confirming = action
            } else {
                error = "The Confirm isn't waiting any more."
                await refresh()
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// The errand in its card while it's going, drawn by the app (ErrandStage) from what the page is and what Aide
/// does, with Aide's line for it underneath. On a login, a code or a CAPTCHA, it (and its button) opens your part.
struct ErrandLiveBox: View {
    let errand: Errand
    let tint: Color
    let open: () -> Void

    @StateObject private var live = BrowserLive()
    @EnvironmentObject private var env: AppEnvironment
    @AppStorage("errandLiveBox") private var shown = true
    @State private var caption: String?

    /// While there's a page to show: not before it starts, not after it's over, not after a restart closed it.
    static func shows(_ e: Errand) -> Bool {
        !e.isOver && e.status != "interrupted" && (e.status != "queued" || e.url != nil)
    }

    /// The line under it: what Aide says it's doing, else what it did, else the errand's step.
    static func narration(action: BrowserLive.Action?, step: String?) -> String {
        action?.said ?? step ?? "Opening the page…"
    }

    private static let height: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.4)) { shown.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari").font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text("Aide's browser").font(.caption.weight(.semibold))
                    if !shown {
                        Text(caption ?? errand.step ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(shown ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shown ? "Hide Aide's browser" : "Show Aide's browser")
            if shown {
                VStack(alignment: .leading, spacing: 8) {
                    stage
                    if !errand.needsLiveView {
                        Narration(text: caption ?? errand.step ?? "Opening the page…", tint: tint)
                    }
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                        removal: .opacity))
            }
        }
        .task(id: shown) {
            guard shown else { return live.disconnect() }
            // Keeps it open: a page that isn't there yet (just started) or a dropped socket is tried again.
            while !Task.isCancelled {
                if !live.connected, let request = try? env.api.browserLiveRequest(errand: errand.id, frames: false) {
                    live.connect(request)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear { live.disconnect() }
        .onChange(of: live.action) { _, action in caption = Self.narration(action: action, step: caption) }
        .onChange(of: live.status?.step) { _, step in if let step { caption = step } }
    }

    private var stage: some View {
        ErrandStage(scene: live.scene, action: live.action, tint: tint,
                    confirming: errand.status == "waiting_confirm",
                    yourTurn: errand.needsLiveView ? open : nil)
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { if errand.needsLiveView { open() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Aide's browser")
            .accessibilityValue(caption ?? "")
    }
}

/// Where Aide just tapped or typed: a dot with a ring spreading from it.
struct TapMark: View {
    let tint: Color
    @State private var spread = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.35)).frame(width: 26, height: 26)
            Circle().stroke(tint, lineWidth: 2.5).frame(width: 26, height: 26)
                .scaleEffect(spread ? 2.4 : 1)
                .opacity(spread ? 0 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 3)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).repeatCount(3, autoreverses: false)) { spread = true }
        }
        .accessibilityHidden(true)
    }
}

/// The circle in front of an errand: what it's doing at a glance.
struct ErrandIcon: View {
    let errand: Errand
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(errand.status == "needs_you" || errand.status == "waiting_confirm" ? Color.white : Theme.onAccent)
            .frame(width: 42, height: 42)
            .background(background, in: Circle())
    }

    private var symbol: String {
        switch errand.status {
        case "needs_you": errand.needsAnswer ? "questionmark" : "hand.raised.fill"
        case "waiting_confirm": "checkmark.shield.fill"
        case "done": "checkmark"
        case "failed": "exclamationmark.triangle.fill"
        case "cancelled": "xmark"
        case "interrupted": "pause.fill"
        default: "safari.fill"
        }
    }

    private var background: Color {
        switch errand.status {
        case "needs_you", "waiting_confirm": .orange
        case "failed": .red.opacity(0.8)
        default: tint
        }
    }
}

/// What you can do with an errand now. Shared by the chat card and Waiting for you.
struct ErrandButtons: View {
    let errand: Errand
    let busy: Bool
    let takeOver: () -> Void
    let answer: (String) -> Void
    let review: () -> Void
    let cancel: () -> Void

    var body: some View {
        if !errand.isOver {
            VStack(spacing: 8) {
                if errand.needsAnswer, let options = errand.options, !options.isEmpty {
                    ForEach(options, id: \.self) { option in
                        Button { answer(option) } label: { Text(option).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                }
                if let title = primaryTitle {
                    HStack(spacing: 10) {
                        primary(title, action: primaryAction)
                        Button(role: .destructive, action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    // Only watching: the box above shows it, so just a small way to stop it.
                    Button("Stop", role: .destructive, action: cancel)
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .disabled(busy)
        }
    }

    private var primaryTitle: String? {
        if errand.needsLiveView { return Self.yourPart(errand) }
        if errand.status == "waiting_confirm" { return "Review and confirm" }
        if errand.status == "interrupted" { return "Go on" }
        return nil
    }

    private func primaryAction() {
        if errand.needsLiveView { takeOver() }
        else if errand.status == "waiting_confirm" { review() }
        else { answer("go on") }
    }

    /// The button for your part of an errand that needs you.
    static func yourPart(_ e: Errand) -> String {
        switch e.why {
        case "login": "Log in"
        case "code": "Enter the code"
        case "captcha": "Solve it"
        default: "Take over"
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
    }
}

/// An order an errand placed: what, the total, the order number and the confirmation page.
struct PurchaseCard: View {
    let purchase: Purchase
    @State private var showsReceipt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "bag.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(purchase.title).font(.headline).lineLimit(2)
                    Text([purchase.site, purchase.date?.formatted(date: .abbreviated, time: .shortened)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(purchase.total).font(.title3.weight(.bold)).monospacedDigit()
            }
            if !purchase.items.isEmpty { PurchaseItems(items: purchase.items) }
            VStack(alignment: .leading, spacing: 6) {
                if let ref = purchase.orderRef { Label("Order \(ref)", systemImage: "number") }
                if let delivery = purchase.delivery { Label(delivery, systemImage: "shippingbox") }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if purchase.receipt != nil {
                Button { showsReceipt = true } label: {
                    Label("Confirmation page", systemImage: "doc.text.image").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showsReceipt) { PagePhotoSheet(title: "Confirmation", photo: purchase.receipt) }
    }
}

/// An order's lines: picture, title, quantity, price.
struct PurchaseItems: View {
    let items: [PurchaseItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    AsyncImage(url: item.image.flatMap(URL.init(string:))) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "shippingbox").foregroundStyle(.tertiary)
                    }
                    .frame(width: 44, height: 44)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline).lineLimit(3)
                        if let q = item.quantity, q != 1 {
                            Text("× \(q)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    if let price = item.price { Text(price).font(.subheadline.weight(.medium)).monospacedDigit() }
                }
            }
        }
    }
}

/// The order an errand asks you to confirm, as the checkout showed it.
struct PurchaseSummary: View {
    let detail: PurchaseDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let items = detail.items, !items.isEmpty { PurchaseItems(items: items) }
            VStack(alignment: .leading, spacing: 6) {
                if let delivery = detail.delivery { Label(delivery, systemImage: "shippingbox") }
                if let address = detail.address { Label(address, systemImage: "mappin.and.ellipse") }
                if let site = detail.site { Label("The card saved on \(site)", systemImage: "creditcard") }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let total = detail.total {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(total).font(.title3.weight(.bold)).monospacedDigit()
                }
            }
        }
    }
}

/// An order to confirm, full size: the items, the checkout page, and Confirm.
struct PurchaseConfirmSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let action: QueuedAction
    let done: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(action.purchase?.summary ?? action.summary).font(.title3.weight(.semibold))
                    if let detail = action.purchase {
                        PurchaseSummary(detail: detail)
                            .padding(14)
                            .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        if let button = detail.button {
                            Text("Confirm and Aide presses \u{201C}\(button)\u{201D} on \(detail.site ?? "the site"), only if the total is still the same.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let shot = detail.screenshot {
                            Text("The checkout page").font(.headline)
                            ServerPhoto(id: shot, fit: true)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .background(Theme.grouped)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(role: .cancel) { Task { await answer(confirm: false) } } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await answer(confirm: true) } } label: {
                        Text(action.purchase?.total.map { "Confirm · \($0)" } ?? "Confirm").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                }
                .controlSize(.large)
                .disabled(busy)
                .padding(16)
                .background(.bar)
            }
            .navigationTitle("Confirm the order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }

    private func answer(confirm: Bool) async {
        busy = true
        defer { busy = false }
        do {
            if confirm {
                let result = try await env.api.confirm(ids: [action.id]).result
                if result.contains("✗") { error = result; return }
            } else {
                _ = try await env.api.cancel(ids: [action.id])
            }
            await done()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// A page Aide's browser saw (a checkout, a confirmation), full size.
struct PagePhotoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let photo: String?

    var body: some View {
        NavigationStack {
            ScrollView { ServerPhoto(id: photo, fit: true).padding(16) }
                .background(Theme.grouped)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Waiting for you

/// An errand that needs you, in Waiting for you: take over, answer, or go on after a restart.
struct ErrandWaitingRow: View {
    let errand: Errand
    let agent: Agent
    let busy: Bool
    let takeOver: () -> Void
    let answer: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: agent, size: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(errand.title)
                    Text("\(errand.siteName) · \(errand.line)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            ErrandButtons(errand: errand, busy: busy, takeOver: takeOver, answer: answer, review: {}, cancel: cancel)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings

/// Settings → Browser: the sites Aide's browser is logged in to, logging in to one, and what errands bought.
struct BrowserSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var sites: [BrowserSite] = []
    @State private var enabled = true
    @State private var loaded = false
    @State private var address = ""
    @State private var opening = false
    @State private var browser: BrowserTarget?
    @State private var error: String?

    var body: some View {
        Form {
            if loaded && !enabled {
                Section {
                    Text("The server has no browser yet: Playwright's Chromium isn't installed there.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if sites.isEmpty {
                    Text(loaded ? "None yet" : "Loading…").foregroundStyle(.secondary)
                }
                ForEach(sites) { site in
                    LabeledContent(site.site) {
                        if let used = site.usedAt.flatMap(Wire.parse) {
                            Text(used.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in Task { await forget(offsets.map { sites[$0] }) } }
            } header: {
                Text("Sites")
            } footer: {
                Text("Aide's browser keeps you logged in on these. Swipe one to forget it: its cookies go and you're logged out there.")
            }
            Section {
                TextField("amazon.it", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await open() } }
                Button {
                    Task { await open() }
                } label: {
                    HStack { Text("Log in"); if opening { Spacer(); ProgressView() } }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || opening || !enabled)
            } header: {
                Text("Log in to a site")
            } footer: {
                Text("Opens the site in Aide's browser and its login here, on Aide's own screen. Your passwords and codes go to the page, never to Aide.")
            }
            Section {
                NavigationLink("Purchases") { PurchasesView() }
            } footer: {
                Text("Errands never buy, book or send anything without your Confirm, and never type card numbers.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Browser")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $browser) { target in
            StageSheet(target: target) { Task { await load() } }
        }
    }

    private func load() async {
        do {
            let list = try await env.api.browserSites()
            sites = list.sites
            enabled = list.enabled
            error = nil
        } catch APIError.server(404, _) {
            enabled = false
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func open() async {
        let url = address.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        opening = true
        defer { opening = false }
        do {
            let opened = try await env.api.openSite(url)
            address = ""
            browser = .site(opened.site)
        } catch { self.error = error.localizedDescription }
    }

    private func forget(_ gone: [BrowserSite]) async {
        for site in gone {
            do { try await env.api.forgetSite(site.site) } catch { self.error = error.localizedDescription }
        }
        await load()
    }
}

/// What errands have bought, newest first, with the totals.
struct PurchasesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var list: PurchaseList?
    @State private var error: String?

    var body: some View {
        List {
            if let list {
                if list.purchases.isEmpty {
                    Text("Nothing yet. When an errand places an order, it's kept here and Finance sees it.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(list.purchases) { p in
                            PurchaseCard(purchase: p)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(totals(list))
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Purchases")
        .task { await load() }
        .refreshable { await load() }
    }

    private func totals(_ list: PurchaseList) -> String {
        let sums = list.totals.sorted { $0.key < $1.key }
            .map { $0.value.formatted(.currency(code: $0.key)) }
        return sums.isEmpty ? "Last 90 days" : "Last 90 days · \(sums.joined(separator: " + "))"
    }

    private func load() async {
        do { list = try await env.api.purchases(days: 90) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - What an errand found

/// The products an errand found, best first, side by side: picture, name, price, stars. A tap opens it on the site
/// (the shop's app when it's installed).
struct ProductsCard: View {
    let products: [Product]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(products.enumerated()), id: \.offset) { ProductTile(product: $0.element) }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

struct ProductTile: View {
    @Environment(\.openURL) private var openURL
    let product: Product

    var body: some View {
        Button {
            if let link = product.link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                picture
                    .frame(width: 168, height: 150)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    if let price = product.price {
                        Text(price).font(.headline).monospacedDigit()
                    }
                    if let stars = product.stars {
                        Text(stars).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = product.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .frame(width: 184, alignment: .topLeading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens it on the site")
    }

    @ViewBuilder
    private var picture: some View {
        AsyncImage(url: product.image.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fit).padding(8)
            case .failure: placeholder
            default: if product.image == nil { placeholder } else { ProgressView() }
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "bag").font(.title).foregroundStyle(.tertiary)
    }
}
