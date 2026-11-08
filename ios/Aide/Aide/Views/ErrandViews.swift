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

    var errand: Int? { if case .errand(let id, _) = self { id } else { nil } }
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
    /// To open again after a drop (the phone moving from mobile data to Wi-Fi, Tailscale reconnecting).
    private var request: URLRequest?
    private var retries = 0
    private static let retryAfter: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]

    var control: Bool { status?.control ?? false }
    /// Open and not closed by the server.
    var connected: Bool { task != nil && closed == nil }

    /// Errands whose live view is on screen (a count each: a sheet can open over another), so their pushes stay quiet.
    private(set) static var watching: [Int: Int] = [:]
    private var errand: Int?

    func connect(_ request: URLRequest, errand: Int? = nil) {
        disconnect()
        closed = nil
        if let errand {
            self.errand = errand
            Self.watching[errand, default: 0] += 1
        }
        self.request = request
        retries = 0
        open(request)
    }

    private func open(_ request: URLRequest) {
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        reader = Task { [weak self] in await self?.read(task) }
    }

    func disconnect() {
        if let errand {
            Self.watching[errand] = (Self.watching[errand] ?? 1) > 1 ? Self.watching[errand]! - 1 : nil
            self.errand = nil
        }
        reader?.cancel()
        reader = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        request = nil
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
                // A drop, not the server closing it on purpose: open it again, quietly, a few times.
                let dropped = [.invalid, .abnormalClosure, .goingAway].contains(task.closeCode)
                if dropped, let request, retries < Self.retryAfter.count {
                    try? await Task.sleep(for: Self.retryAfter[retries])
                    guard !Task.isCancelled, self.task === task else { return }
                    retries += 1
                    open(request)
                    return
                }
                closed = task.closeCode == .policyViolation ? "The server didn't open this page."
                    : "The live view closed."
                return
            }
            retries = 0
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
        if let request { live.connect(request, errand: target.errand) }
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
    /// The same errand's card comes again further down: just its line here.
    private let folded: Bool
    /// The chat message above it: when that says the question already, the card doesn't say it again.
    private let said: String

    init(errand: Errand, folded: Bool = false, said: String = "") {
        _errand = State(initialValue: errand)
        self.folded = folded
        self.said = said
    }

    private var saysLine: Bool {
        guard let reason = errand.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty,
              errand.line == errand.reason else { return true }
        return !said.contains(reason)
    }

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
            if !errand.isOver, !folded, saysLine {
                Text(errand.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            if !folded, ErrandLiveBox.shows(errand) {
                ErrandLiveBox(errand: errand, tint: chat.agent("aide").tint) {
                    browser = .errand(errand.id, title: errand.title)
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                        removal: .opacity))
            }
            if !folded {
                ErrandButtons(errand: errand, busy: busy,
                              takeOver: { browser = .errand(errand.id, title: errand.title) },
                              answer: { answer in
                                  Task { await act { try await env.api.replyErrand(errand.id, answer: answer) } }
                              },
                              review: { Task { await review() } },
                              cancel: { Task { await act { try await env.api.cancelErrand(errand.id) } } })
            }
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
        .stage(item: $browser, tint: chat.agent("aide").tint) { Task { await refresh() } }
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
        case "waiting_confirm": e.drop != nil ? "Waiting for your limits" : "Waiting for your Confirm"
        case "scheduled": "Waiting for the sale"
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
            try? await Task.sleep(for: .seconds(errand.isWorking ? 4 : errand.status == "scheduled" ? 60 : 15))
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
        guard changed else { return }
        if let id = fresh.conversationId, id == chat.conversationID {
            await chat.loadHistory()
        } else if fresh.conversationId == nil, chat.conversationID != nil {
            // An errand without a chat of its own (Esse3) posts its result in the chat it was asked from, just after
            // it stops: this card is in that chat.
            try? await Task.sleep(for: .seconds(3))
            await chat.loadHistory()
        }
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

    /// While there's a page to show: not before it starts, not after it's over, not after a restart closed it,
    /// and not while it asks you something (the question and its answers are the card; the page is beside the point).
    static func shows(_ e: Errand) -> Bool {
        !e.isOver && !e.needsAnswer && !["interrupted", "scheduled"].contains(e.status)
            && (e.status != "queued" || e.url != nil)
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
                    live.connect(request, errand: errand.id)
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
        case "scheduled": "clock.fill"
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
                if errand.needsAnswer, let choices = errand.choices, !choices.isEmpty {
                    #if os(macOS)
                    // The Mac has the room: every answer in view, wrapped to the card's width.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(choices) { choice in
                            ChoiceTile(choice: choice) { answer(choice.title) }
                        }
                    }
                    #else
                    // A row to swipe, kept inside the card (unclipped it ran past the card's edge).
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(choices) { choice in
                                ChoiceTile(choice: choice) { answer(choice.title) }
                            }
                        }
                    }
                    #endif
                } else if errand.needsAnswer, let options = errand.options, !options.isEmpty {
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
        if errand.status == "waiting_confirm" { return errand.drop != nil ? "Review the limits" : "Review and confirm" }
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
                if detail.pays, let site = detail.site { Label("The card saved on \(site)", systemImage: "creditcard") }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let total = detail.total, detail.pays {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(total).font(.title3.weight(.bold)).monospacedDigit()
                }
            }
        }
    }
}

/// A timed drop's limits, as you confirm them once before the sale.
struct DropSummary: View {
    let detail: PurchaseDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = detail.item {
                HStack(alignment: .firstTextBaseline) {
                    Text([item, detail.variant].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.medium)).lineLimit(3)
                    Spacer(minLength: 6)
                    if let q = detail.quantity, q != 1 { Text("× \(q)").font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let window = Self.window(detail) { Label(window, systemImage: "clock") }
                if let address = detail.address { Label(address, systemImage: "mappin.and.ellipse") }
                if let card = detail.card ?? detail.site.map({ "The card saved on \($0)" }) {
                    Label(card, systemImage: "creditcard")
                }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let max = detail.maxTotal {
                HStack {
                    Text("Up to").font(.headline)
                    Spacer()
                    Text(max).font(.title3.weight(.bold)).monospacedDigit()
                }
                Text("With shipping").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// "Thu 6 Nov 10:00 – 12:00"
    static func window(_ d: PurchaseDetail) -> String? {
        guard let opens = d.opensAt.flatMap(Wire.parse) else { return nil }
        let start = DropTime.text(opens).capitalizingFirst
        guard let closes = d.closesAt.flatMap(Wire.parse) else { return start }
        return "\(start) – \(closes.formatted(date: .omitted, time: .shortened))"
    }

    static func rule(_ d: PurchaseDetail) -> String {
        let max = d.maxTotal ?? "your limit"
        return "At the sale Aide buys on \(d.site ?? "the site") only if the page names this item\(d.variant == nil ? "" : " and variant") "
            + "and the total is \(max) or less. Anything else stops and asks you. A login, a queue or a card check "
            + "is yours, so be around then."
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// An order to confirm, full size: the items, the checkout page, and Confirm. Without a total (a form, a
/// questionnaire) it's only the button Aide will press and the page it's on.
struct PurchaseConfirmSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let action: QueuedAction
    let done: () async -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var page: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(action.detail?.summary ?? action.summary).font(.title3.weight(.semibold))
                    if let drop = action.drop {
                        DropSummary(detail: drop)
                            .padding(14)
                            .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text(DropSummary.rule(drop)).font(.footnote).foregroundStyle(.secondary)
                        if let risk = drop.risk {
                            Label(risk + ".", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        if let shot = drop.screenshot {
                            Text("The product page").font(.headline)
                            ServerPhoto(id: shot, fit: true)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    if let detail = action.purchase {
                        if detail.hasSummary {
                            PurchaseSummary(detail: detail)
                                .padding(14)
                                .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        if let button = detail.button {
                            Text("Confirm and Aide presses \u{201C}\(button)\u{201D} on \(detail.site ?? "the site")"
                                 + (detail.pays ? ", only if the total is still the same." : "."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let shot = detail.screenshot {
                            HStack {
                                Text(detail.pays ? "The checkout page" : "The page").font(.headline)
                                Spacer()
                                Button("Full size") { page = shot }.font(.subheadline)
                            }
                            // The whole page since 2026-11-08 (a questionnaire to check answer by answer): scroll the
                            // sheet through it, or open it full size.
                            Button { page = shot } label: {
                                ServerPhoto(id: shot, fit: true)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
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
                        Text(confirmTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                }
                .controlSize(.large)
                .disabled(busy)
                .padding(16)
                .background(.bar)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .sheet(item: Binding(get: { page.map(PageShot.init) }, set: { page = $0?.id })) {
                PagePhotoSheet(title: title, photo: $0.id).macCoverSize()
            }
        }
    }

    private struct PageShot: Identifiable { let id: String }

    private var title: String {
        if action.drop != nil { return "Confirm the limits" }
        if let detail = action.purchase, !detail.pays { return detail.site.map { "Confirm on \($0)" } ?? "Confirm" }
        return "Confirm the order"
    }

    private var confirmTitle: String {
        if let drop = action.drop { return drop.maxTotal.map { "Confirm · up to \($0)" } ?? "Confirm" }
        guard let detail = action.purchase, detail.pays, let total = detail.total else { return "Confirm" }
        return "Confirm · \(total)"
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
            ZoomablePage { ServerPhoto(id: photo, fit: true).padding(16) }
                .background(Theme.grouped)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A tall page picture to read closely: scrolls, and pinches (or ⌘+ / ⌘− and the trackpad on the Mac) to zoom in.
private struct ZoomablePage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { box in
            ScrollView([.vertical, .horizontal]) {
                content()
                    .frame(width: box.size.width * zoom * pinch)
            }
            .gesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { zoom = min(max(zoom * $0.magnification, 1), 4); pinch = 1 })
            .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { withAnimation { zoom = max(zoom / 1.5, 1) } } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).disabled(zoom <= 1)
                Button { withAnimation { zoom = min(zoom * 1.5, 4) } } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("+", modifiers: .command).disabled(zoom >= 4)
            }
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
                NavigationLink("Price watches") { PriceWatchesView().macPageBack() }
                NavigationLink("Releases") { ReleasesView().macPageBack() }
                NavigationLink("Purchases") { PurchasesView().macPageBack() }
            } footer: {
                Text("Price watches read a page every few hours and tell you once. Releases follow a drop's dates and set it up for you. Errands never buy, book or send anything without your Confirm, and never type card numbers.")
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
        .stage(item: $browser) { Task { await load() } }
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
    /// The errand the cards came from: Buy it for me starts from it.
    var errand: Int?
    var site: String?
    /// After Buy it for me or a watch (the chat loads again).
    var changed: (() async -> Void)?
    @State private var opened: Product?
    /// Men's, Women's or every product, when the cards are both; the last choice is kept.
    @AppStorage("products.audience") private var audience = ""

    /// Who the products are for, when there's more than one kind of buyer among them ("men", "women").
    private var audiences: [String] {
        let kinds = Set(products.compactMap(\.audience).filter { $0 != "unisex" })
        return ["men", "women", "kids"].filter(kinds.contains)
    }

    private var shown: [Product] {
        guard audiences.count > 1, audiences.contains(audience) else { return products }
        return products.filter { $0.audience == audience || $0.audience == "unisex" || $0.audience == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if audiences.count > 1 {
                HStack(spacing: 6) {
                    chip("", "All")
                    ForEach(audiences, id: \.self) { chip($0, Self.label($0)) }
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { item in
                        ProductTile(product: item.element) { opened = item.element }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
        .sheet(item: $opened) { p in
            ProductSheet(products: shown, start: p, errand: errand, site: site, changed: changed)
        }
    }

    private func chip(_ value: String, _ title: String) -> some View {
        let on = value == audience || (value.isEmpty && !audiences.contains(audience))
        let count = value.isEmpty ? products.count
            : products.filter { $0.audience == value || $0.audience == "unisex" || $0.audience == nil }.count
        return Button { audience = value } label: {
            Text("\(title) \(count)").font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? Theme.onAccent : .primary)
                .background(on ? Theme.accent : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    static func label(_ audience: String) -> String {
        switch audience {
        case "men": "Men's"
        case "women": "Women's"
        case "kids": "Kids'"
        default: "Everyone"
        }
    }
}

struct ProductTile: View {
    let product: Product
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ProductPicture(product: product)
                    .frame(width: 168, height: 150)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let off = product.off {
                            Text(off).font(.caption.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .foregroundStyle(.white).background(Color.red, in: Capsule()).padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    if let price = product.price {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(price).font(.headline).monospacedDigit()
                            if let was = product.was, product.off != nil {
                                Text(was).font(.caption).monospacedDigit().strikethrough().foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let stars = product.stars {
                        Text(stars).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = product.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
        .accessibilityHint("Opens its page")
    }
}

/// An answer to an errand's question as the site shows it (a kind of food, a restaurant, a dish): a tap answers.
struct ChoiceTile: View {
    let choice: ErrandChoice
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                picture
                    .frame(width: 148, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !line.isEmpty {
                        Text(line).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let note = choice.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(6)
            .frame(width: 160, alignment: .topLeading)
            .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Answers with this")
    }

    private var line: String { [choice.price, choice.stars].compactMap { $0 }.joined(separator: " · ") }

    private var picture: some View {
        AsyncImage(url: choice.image.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            case .failure: placeholder
            default: if choice.image == nil { placeholder } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .background(Color.secondary.opacity(0.12))
    }

    private var placeholder: some View {
        Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProductPicture: View {
    let product: Product
    var padding: CGFloat = 8

    var body: some View {
        AsyncImage(url: product.image.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fit).padding(padding)
            case .failure: placeholder
            default: if product.image == nil { placeholder } else { ProgressView() }
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "bag").font(.title).foregroundStyle(.tertiary)
    }
}

/// A product card opened: its page drawn in Aide, as a shop shows it, with what Aide can do from here: buy it in
/// one of your sizes (an errand, which asks you to confirm the total before paying), or watch its price.
struct ProductSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let products: [Product]
    let errand: Int?
    let site: String?
    let changed: (() async -> Void)?
    @State private var page: String
    @State private var size: String?
    @State private var typedSize = ""
    @State private var maxText = ""
    @State private var watchText = ""
    @State private var busy = false
    @State private var done: String?
    @State private var error: String?

    init(products: [Product], start: Product, errand: Int?, site: String?, changed: (() async -> Void)?) {
        self.products = products.contains(start) ? products : [start] + products
        self.errand = errand
        self.site = site
        self.changed = changed
        _page = State(initialValue: start.id)
        _size = State(initialValue: start.mySizes.count == 1 ? start.mySizes[0] : nil)
        _maxText = State(initialValue: Self.money(start.price.flatMap(Product.amount)))
        _watchText = State(initialValue: Self.money(start.price.flatMap(Product.amount).map { ($0 * 0.9).rounded(.down) }))
    }

    private var current: Product { products.first { $0.id == page } ?? products[0] }

    private var shop: String {
        site ?? current.link?.host?.replacingOccurrences(of: "www.", with: "") ?? "the shop"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ReleaseBar(title: current.title, busy: busy, close: { dismiss() },
                           address: "\(shop) · \(current.title.lowercased())")
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        gallery
                        info
                        sizes
                        limit
                        watch
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .pageColumn()
                }
                .background(Theme.background)
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .macSheetHidesClose()
        }
        .onChange(of: page) {
            size = current.mySizes.count == 1 ? current.mySizes[0] : nil
            maxText = Self.money(current.price.flatMap(Product.amount))
            watchText = Self.money(current.price.flatMap(Product.amount).map { ($0 * 0.9).rounded(.down) })
            error = nil
        }
    }

    // The picture, as big as a shop's, with the discount and who it's for; swipe, the arrows or a thumbnail to move.
    private var gallery: some View {
        VStack(spacing: 12) {
            ProductPicture(product: current, padding: 18)
                .id(current.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity).frame(height: 260)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if let off = current.off { pill(off, colour: .red) }
                        if let a = current.audience, a != "unisex" { pill(ProductsCard.label(a), colour: .black.opacity(0.6)) }
                    }
                    .padding(10)
                }
                .overlay {
                    if products.count > 1 {
                        HStack { arrow("chevron.left", by: -1); Spacer(); arrow("chevron.right", by: 1) }
                            .padding(.horizontal, 8)
                    }
                }
                .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    move(v.translation.width < 0 ? 1 : -1)
                })
            if products.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(products) { p in
                            Button { withAnimation(.easeInOut(duration: 0.2)) { page = p.id } } label: {
                                ProductPicture(product: p, padding: 4)
                                    .frame(width: 52, height: 52)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(p.id == page ? Theme.accent : Theme.line,
                                                          lineWidth: p.id == page ? 2.5 : 0.5)
                                    }
                                    .opacity(p.id == page ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(current.title).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = current.price { Text(price).font(.title2.weight(.bold)).monospacedDigit() }
                if let was = current.was, current.off != nil {
                    Text(was).font(.subheadline).monospacedDigit().strikethrough().foregroundStyle(.secondary)
                }
                Spacer()
                if let saved { Text("You save \(saved)").font(.footnote.weight(.semibold)).foregroundStyle(.green) }
            }
            if let stars = current.stars { Text(stars).font(.footnote).foregroundStyle(.secondary) }
            if current.mySizes.isEmpty, let note = current.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var saved: String? {
        guard current.off != nil, let was = current.was.flatMap(Product.amount),
              let now = current.price.flatMap(Product.amount) else { return nil }
        return Self.money(was - now) + " €"
    }

    // Your sizes in stock, from Aide's look; one to buy. A product without them: type one if it has sizes.
    @ViewBuilder
    private var sizes: some View {
        let mine = current.mySizes
        if mine.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Size").font(.headline)
                TextField("If it comes in sizes", text: $typedSize)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your sizes in stock").font(.headline)
                    Spacer()
                    Text("EU · on \(shop)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                    ForEach(mine, id: \.self) { s in
                        Button { size = size == s ? nil : s } label: {
                            Text(s).font(.subheadline.weight(.medium)).monospacedDigit()
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .foregroundStyle(size == s ? Theme.onAccent : .primary)
                                .background(size == s ? Theme.accent : Theme.chip,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var limit: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Most you'd pay").font(.headline)
                Spacer()
                TextField("Any", text: $maxText)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .keyboardType(.decimalPad)
                    .frame(width: 90)
                Text("€").foregroundStyle(.secondary)
            }
            Text("Aide fills the bag on \(shop) and asks you to confirm the total before anything is paid. Above this it stops and asks.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var watch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not yet?").font(.headline)
            HStack(spacing: 8) {
                Text("Tell me when it's under").font(.subheadline)
                TextField("", text: $watchText)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .keyboardType(.decimalPad)
                    .frame(width: 70)
                Text("€").foregroundStyle(.secondary)
                Spacer()
                Button("Watch") { Task { await addWatch() } }
                    .buttonStyle(.bordered)
                    .disabled(busy || Self.value(watchText) == nil)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.onAccent)
            } else {
                Button { Task { await buy() } } label: {
                    HStack {
                        Text(buyTitle)
                        if busy { ProgressView().tint(Theme.onAccent) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.onAccent)
                .disabled(!canBuy || busy)
                if let link = current.link {
                    Button { openURL(link) } label: {
                        Label("Open on \(shop)", systemImage: "safari").font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.large)
        .padding(16)
        .background(.bar)
    }

    private var chosenSize: String? {
        if let size { return "EU \(size)" }
        let typed = typedSize.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }

    private var canBuy: Bool { errand != nil && (current.mySizes.isEmpty || size != nil) }

    private var buyTitle: String {
        if errand == nil { return "Ask Aide in the chat to buy it" }
        if !current.mySizes.isEmpty && size == nil { return "Pick a size" }
        return "Buy it for me" + (chosenSize.map { " · \($0)" } ?? "")
    }

    private func buy() async {
        guard let errand else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await env.api.buyProduct(errand: errand, ProductBuy(url: current.url, size: chosenSize,
                                                                        maxTotal: Self.value(maxText)))
            done = "Aide is on it. It'll ask you to confirm the total in the chat before paying."
            error = nil
            await changed?()
        } catch { self.error = error.localizedDescription }
    }

    private func addWatch() async {
        guard let below = Self.value(watchText) else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await env.api.addPriceWatch(PriceWatchIn(url: current.url, title: current.title, below: below,
                                                             errandId: errand))
            done = "Watching it. Aide posts in the chat when it's under \(Self.money(below)) €."
            error = nil
            await changed?()
        } catch { self.error = error.localizedDescription }
    }

    private func move(_ by: Int) {
        guard let i = products.firstIndex(where: { $0.id == page }), products.indices.contains(i + by) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = products[i + by].id }
    }

    private func arrow(_ symbol: String, by: Int) -> some View {
        let i = products.firstIndex { $0.id == page } ?? 0
        let can = products.indices.contains(i + by)
        return Button { move(by) } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.black.opacity(0.7))
                .background(.white.opacity(0.85), in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(can ? 1 : 0)
        .disabled(!can)
    }

    private func pill(_ text: String, colour: Color) -> some View {
        Text(text).font(.caption.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(colour, in: Capsule())
    }

    static func value(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func money(_ amount: Double?) -> String {
        amount.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? ""
    }
}

// MARK: - Price watches

/// A price watch: the price now, the line, and what you can do (buy it, look now, stop, watch again).
struct PriceWatchCard: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var watch: PriceWatch
    @State private var busy = false
    @State private var note: String?
    @State private var error: String?
    /// After Buy it starts an errand (in the watch's chat).
    var bought: ((Errand) async -> Void)?
    /// Gone from the server (Settings' list drops it).
    var deleted: (() -> Void)?
    /// In a chat the card is the watch as it was: load it fresh once.
    private let refreshes: Bool

    init(watch: PriceWatch, refreshes: Bool = true, bought: ((Errand) async -> Void)? = nil, deleted: (() -> Void)? = nil) {
        _watch = State(initialValue: watch)
        self.refreshes = refreshes
        self.bought = bought
        self.deleted = deleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(watch.status == "met" ? Color.white : Theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background(watch.status == "met" ? Color.green : watch.status == "failed" ? Color.red.opacity(0.8) : Theme.accent,
                                in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(watch.title).font(.headline).lineLimit(2)
                    Text([watch.site, watch.state].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let price = watch.shownPrice {
                    Text(price).font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(watch.status == "met" ? Color.green : Color.primary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(watch.goal, systemImage: "target")
                if let coupon = watch.coupon { Label(coupon, systemImage: "ticket") }
                if let lowest = watch.lowest, watch.history.count > 1 {
                    Label("Lowest seen \(PriceWatch.money(lowest, watch.currency))", systemImage: "arrow.down.right")
                }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            buttons.disabled(busy)
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            if let link = watch.link { Link(destination: link) { Label("Open the page", systemImage: "safari") } }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete() } }
        }
        .task(id: watch.id) { if refreshes { await refresh() } }
    }

    private var icon: String {
        switch watch.status {
        case "met": "checkmark"
        case "failed": "exclamationmark.triangle.fill"
        case "ended": "pause.fill"
        default: watch.below == nil ? "shippingbox.fill" : "tag.fill"
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch watch.status {
            case "met":
                prominent("Buy it") { await buy() }
                plain("Watch again") { await act { try await env.api.updatePriceWatch(watch.id, PriceWatchPatch(status: "active")) } }
            case "active":
                plain("Check now") { await act { try await env.api.checkPriceWatch(watch.id) } }
                Button(role: .destructive) {
                    Task { await act { try await env.api.updatePriceWatch(watch.id, PriceWatchPatch(status: "ended")) } }
                } label: { Text("Stop").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            default:
                plain("Watch again") { await act { try await env.api.updatePriceWatch(watch.id, PriceWatchPatch(status: "active")) } }
            }
        }
    }

    private func prominent(_ title: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
    }

    private func plain(_ title: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }

    private func refresh() async {
        guard let list = try? await env.api.priceWatches() else { return }
        if let fresh = list.priceWatches.first(where: { $0.id == watch.id }) { watch = fresh } else if list.enabled {
            note = "This watch was deleted."
        }
    }

    private func act(_ call: () async throws -> PriceWatch) async {
        busy = true
        defer { busy = false }
        do { watch = try await call(); error = nil; note = nil } catch { self.error = error.localizedDescription }
    }

    private func buy() async {
        busy = true
        defer { busy = false }
        do {
            let errand = try await env.api.buyPriceWatch(watch.id)
            note = "Aide's on it in its chat. Nothing is bought without your Confirm."
            error = nil
            await bought?(errand)
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        do { try await env.api.deletePriceWatch(watch.id); deleted?() ; note = "Deleted." }
        catch { self.error = error.localizedDescription }
    }
}

/// Settings → Browser → Price watches: every watch, active first.
struct PriceWatchesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var list: PriceWatchList?
    @State private var error: String?

    var body: some View {
        List {
            if let list {
                if !list.enabled {
                    Text("The server has no browser yet, so it can't watch prices.").foregroundStyle(.secondary)
                } else if list.priceWatches.isEmpty {
                    Text("None yet. Ask Aide: \u{201C}tell me when the AirPods Pro go under 150 €\u{201D}, or \u{201C}tell me when it's back in stock\u{201D}.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(list.priceWatches) { w in
                            PriceWatchCard(watch: w, refreshes: false, deleted: { Task { await load() } })
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .onDelete { offsets in Task { await delete(offsets.map { list.priceWatches[$0] }) } }
                    } footer: {
                        Text("Each page is read every few hours with no model, and you're told once. Touch and hold one to open its page or delete it.")
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
        .navigationTitle("Price watches")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { list = try await env.api.priceWatches(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func delete(_ gone: [PriceWatch]) async {
        for w in gone {
            do { try await env.api.deletePriceWatch(w.id) } catch { self.error = error.localizedDescription }
        }
        await load()
    }
}
