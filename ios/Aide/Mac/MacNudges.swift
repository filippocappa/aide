import AppKit
import CoreAudio
import SwiftUI

/// Nudges (#84, docs/API.md "Nudges"), only while someone's at this Mac (`MacUsage`'s look every 5 s: touched in the
/// last 2 minutes, or a video playing):
/// - **Bedtime:** tonight's steps from the server (an hour before, half an hour, ten minutes, then every ten minutes),
///   each shown once while it's due; Pebble stays up until it's answered: Snooze 10 min, or I'm going (20 min quiet).
/// - **Off task:** while a study event (or a `#focus` one) is on and the app or site in front, or a video playing, is
///   on the Work list: after a minute, then once more after 15 minutes more. Back to it opens the course's page in
///   Aide (or hides the app); Not now. Pebble goes by itself once you're back on task.
/// Quiet during a call (the microphone in use), a focus session, and for bedtime while another timed event is on.
/// Nothing is quit or locked: Pebble just says so. Aide Guard runs it; the app only while the Guard doesn't.
@MainActor
final class MacNudges {
    private let api: APIClient
    private let card = NudgeCard()
    private var plan: NudgePlan?
    private var steps: [(step: BedtimeStep, at: Date, until: Date)] = []
    private var events: [(event: NudgeEvent, start: Date, end: Date)] = []
    private var fetched = Date.distantPast
    private var fetching = false
    /// Quiet for bedtime until then (Snooze, I'm going).
    private var quietUntil = Date.distantPast
    /// The nudges already shown, by key, so a restart doesn't show them again (kept two days).
    private var shown: [String: Date]
    /// Off task during the focus event on now: since when without a break, the first nudge, the time off since it.
    private var offEvent: String?
    private var offSince: Date?
    private var firstAt: Date?
    private var offAfterFirst: TimeInterval = 0
    private var lastLook: Date?
    private var observers: [NSObjectProtocol] = []

    private static let refresh: TimeInterval = 5 * 60
    private static let offFor: TimeInterval = 60
    private static let againAfter: TimeInterval = 15 * 60
    private static let snooze: TimeInterval = 10 * 60
    private static let going: TimeInterval = 20 * 60
    private static let shownKey = "nudgesShown"

    init(api: APIClient) {
        self.api = api
        shown = (UserDefaults.standard.dictionary(forKey: Self.shownKey) as? [String: Date] ?? [:])
            .filter { Date().timeIntervalSince($0.value) < 2 * 86400 }
        card.answered = { [weak self] content, answer in self?.answered(content, answer) }
        MacUsage.shared.onLook = { [weak self] look in self?.saw(look) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.refreshNow() }
        })
        refreshNow()
    }

    /// The other side stood in (the Guard started, or the app took over): this one does nothing more.
    func stop() {
        MacUsage.shared.onLook = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        card.close()
    }

    /// Something changed (a lock, a list, the server handed over): the plan again.
    func refreshNow() {
        fetched = .distantPast
        Task { await fetch() }
    }

    private func fetch() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        do {
            use(try await api.nudges())
            fetched = Date()
        } catch {
            fetched = Date().addingTimeInterval(-Self.refresh + 60) // again in a minute; the last plan meanwhile
        }
    }

    private func use(_ plan: NudgePlan) {
        var plan = plan
        #if DEBUG
        Self.test(&plan)
        #endif
        self.plan = plan
        steps = (plan.bedtime?.steps ?? []).compactMap { step in
            guard let at = LockClock.date(step.at), let until = LockClock.date(step.until) else { return nil }
            return (step, at, until)
        }
        events = plan.events.compactMap { event in
            guard let start = LockClock.date(event.start), let end = LockClock.date(event.end) else { return nil }
            return (event, start, end)
        }
    }

    // MARK: Each look

    private func saw(_ look: MacUsage.Look) {
        let now = look.at
        if now.timeIntervalSince(fetched) > Self.refresh { Task { await fetch() } }
        let elapsed = lastLook.map { min(max(now.timeIntervalSince($0), 0), 15) } ?? 0
        lastLook = now
        guard let plan else { return }
        let focus = events.first { $0.event.kind != "other" && $0.start <= now && now < $0.end }
        let off = focus != nil && look.present ? offTask(look, plan.list) : nil
        track(focus, off: off, now: now, elapsed: elapsed)

        // What's up and no longer due goes: a bedtime nudge after the last step, an off-task one once back on task.
        switch card.content {
        case .bedtime where step(at: now) == nil:
            card.close()
        case .offtask(let key, _) where off == nil || key != focus.map(Self.key):
            card.close()
        default:
            break
        }
        guard look.present, !plan.focus, !Self.micInUse() else { return }

        if let (step, _, _) = step(at: now), now >= quietUntil,
           !events.contains(where: { $0.event.kind == "other" && $0.start <= now && now < $0.end }) {
            let key = "mac-bedtime-\(plan.bedtime?.date ?? "")-\(step.step)-\(step.at)"
            if shown[key] == nil {
                remember(key, now)
                card.show(.bedtime(key), title: step.title, body: step.body,
                          mood: step.step == "hour" || step.step == "half" ? "calm" : "sleeping",
                          actions: [NudgeAction("Snooze 10 min", "snooze"), NudgeAction("I'm going", "going", prominent: true)],
                          above: Self.front)
                log(NudgeLog(key: key, device: "mac", kind: "bedtime", step: step.step, at: Self.iso(now),
                             night: plan.bedtime?.date, app: look.site ?? look.frontName))
                return
            }
        }
        guard let focus, let off, card.content?.isBedtime != true else { return }
        let step: String
        if firstAt == nil, let offSince, now.timeIntervalSince(offSince) >= Self.offFor {
            step = "first"
            firstAt = now
            offAfterFirst = 0
        } else if firstAt != nil, offAfterFirst >= Self.againAfter {
            step = "again"
            offAfterFirst = -.infinity // once
        } else {
            return
        }
        let eventKey = Self.key(focus)
        let key = "mac-offtask-\(focus.event.start)-\(step)"
        guard shown[key] == nil else { return }
        remember(key, now)
        let until = Self.clock(focus.end)
        let title = step == "first" ? "You're on \(off)" : "Still on \(off)"
        let body = step == "first" ? "The calendar says \(focus.event.title) until \(until)."
            : "Fifteen minutes more; \(focus.event.title) runs until \(until)."
        card.show(.offtask(eventKey, key), title: title, body: body, mood: "awake",
                  actions: [NudgeAction("Not now", "not_now"), NudgeAction("Back to it", "back", prominent: true)],
                  above: Self.front)
        log(NudgeLog(key: key, device: "mac", kind: "offtask", step: step, at: Self.iso(now), app: off,
                     event: focus.event.title, eventStart: focus.event.start, eventEnd: focus.event.end,
                     courseId: focus.event.course?.id))
    }

    private func step(at now: Date) -> (BedtimeStep, Date, Date)? {
        steps.first { $0.at <= now && now < $0.until }
    }

    /// The time off task during the event on now: a minute without a break before the first nudge, then 15 more in
    /// all (breaks or not) before the second.
    private func track(_ focus: (event: NudgeEvent, start: Date, end: Date)?, off: String?, now: Date,
                       elapsed: TimeInterval) {
        let key = focus.map(Self.key)
        if key != offEvent {
            offEvent = key
            offSince = nil
            firstAt = nil
            offAfterFirst = 0
        }
        guard off != nil else {
            offSince = nil
            return
        }
        if offSince == nil { offSince = now }
        if firstAt != nil { offAfterFirst += elapsed }
    }

    /// What's off task in front, or playing beside it: the site, else the app's name.
    private func offTask(_ look: MacUsage.Look, _ list: ScreenList?) -> String? {
        guard let entries = list.map({ Set($0.mac) }), !entries.isEmpty else { return nil }
        var tries: [(entry: String, name: String)] = []
        if let site = look.site { tries.append((MacSites.entry(site), site)) }
        if let front = look.front { tries.append((front, look.frontName ?? front)) }
        tries += look.playingSites.map { (MacSites.entry($0), $0) }
        tries += look.playing.map { ($0.key, $0.value) }
        return tries.first { MacSites.covers(entries, $0.entry) }?.name
    }

    // MARK: Answers

    private func answered(_ content: NudgeCard.Content, _ answer: String) {
        let now = Date()
        switch answer {
        case "snooze": quietUntil = now.addingTimeInterval(Self.snooze)
        case "going": quietUntil = now.addingTimeInterval(Self.going)
        case "back": back()
        default: break
        }
        let key: String
        switch content {
        case .bedtime(let k): key = k
        case .offtask(_, let k): key = k
        }
        Task { [api] in
            // Only the answer goes with the key: the rest is already kept.
            try? await api.logNudge(NudgeLog(key: key, device: "mac", kind: content.isBedtime ? "bedtime" : "offtask",
                                             step: key.hasSuffix("-again") ? "again" : content.isBedtime
                                                 ? Self.bedtimeStep(key) : "first",
                                             at: Self.iso(now), answer: answer))
        }
    }

    /// Back to it: the course's page in Aide, or, for an event without a course, the off-task app out of sight.
    private func back() {
        let now = Date()
        if let course = events.first(where: { $0.event.kind != "other" && $0.start <= now && now < $0.end })?.event.course,
           let url = URL(string: "aide://study/\(course.id)") {
            NSWorkspace.shared.open([url], withApplicationAt: Self.aideApp, configuration: NSWorkspace.OpenConfiguration())
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            front.hide()
        }
    }

    /// Aide.app: this app, or the one the Guard is inside (`Contents/Library/LoginItems/AideGuard.app`).
    private static var aideApp: URL {
        var url = Bundle.main.bundleURL
        if MacGuard.isGuard { for _ in 0..<4 { url.deleteLastPathComponent() } }
        return url
    }

    private static func bedtimeStep(_ key: String) -> String {
        ["hour", "half", "now", "late"].first { key.contains("-\($0)-") } ?? "late"
    }

    // MARK: Helpers

    private func log(_ nudge: NudgeLog) {
        Task { [api] in
            do { try await api.logNudge(nudge) } catch { NSLog("Aide nudges: couldn't log \(nudge.key): \(error)") }
        }
    }

    private func remember(_ key: String, _ at: Date) {
        shown[key] = at
        shown = shown.filter { at.timeIntervalSince($0.value) < 2 * 86400 }
        UserDefaults.standard.set(shown, forKey: Self.shownKey)
    }

    private static func key(_ focus: (event: NudgeEvent, start: Date, end: Date)) -> String {
        "\(focus.event.title)|\(focus.event.start)"
    }

    private static var front: NSPoint? {
        NSWorkspace.shared.frontmostApplication.flatMap(DockIcon.top(of:))
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }

    /// The default microphone is in use by something (a call): quiet.
    private static func micInUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    #if DEBUG
    /// Debug builds: `defaults write <id> nudgeTest -string bedtime` puts bedtime 9 minutes from the plan's fetch
    /// (the "ten minutes" step due at once), `offtask` a study event on now with `nudgeTestApps` (default Notes) as
    /// the Work list. `defaults delete <id> nudgeTest` and `nudgesShown` after.
    private static func test(_ plan: inout NudgePlan) {
        let now = Date()
        switch UserDefaults.standard.string(forKey: "nudgeTest") {
        case "bedtime":
            let bed = now.addingTimeInterval(9 * 60)
            let iso = { (d: Date) in ISO8601DateFormatter().string(from: d) }
            plan.bedtime = BedtimeNudges(date: "test", bedtime: iso(bed), wake: iso(bed.addingTimeInterval(8 * 3600)), steps: [
                BedtimeStep(step: "now", at: iso(bed.addingTimeInterval(-600)), until: iso(bed), title: "Bedtime in ten minutes",
                            body: "It's time to sleep: stop what you're doing."),
                BedtimeStep(step: "late", at: iso(bed), until: iso(bed.addingTimeInterval(600)), title: "Bedtime",
                            body: "It's \(clock(bed)): time to sleep. Stop what you're doing."),
            ])
            plan.focus = false
        case "offtask":
            let iso = { (d: Date) in ISO8601DateFormatter().string(from: d) }
            plan.events.insert(NudgeEvent(id: "test", title: "Study Test", start: iso(now.addingTimeInterval(-60)),
                                          end: iso(now.addingTimeInterval(30 * 60)), kind: "study",
                                          course: nil), at: 0)
            plan.list = ScreenList(id: 0, name: "Work",
                                   mac: UserDefaults.standard.stringArray(forKey: "nudgeTestApps") ?? ["com.apple.Notes"])
            plan.focus = false
        default:
            break
        }
    }
    #endif
}

// MARK: Pebble over the Dock

struct NudgeAction: Hashable {
    let label: String
    let answer: String
    var prominent = false

    init(_ label: String, _ answer: String, prominent: Bool = false) {
        self.label = label
        self.answer = answer
        self.prominent = prominent
    }
}

@MainActor
private final class NudgeCardModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var mood = "calm"
    @Published var actions: [NudgeAction] = []
    @Published var shown = false
    @Published var happy = false
    @Published var pokes = 0
    /// Pebble's distance from the panel's middle, to stand over the icon when the panel meets the screen's edge.
    @Published var shift: CGFloat = 0
    /// Pebble and the card, in the panel (SwiftUI's top-left coordinates): where the panel takes the pointer.
    @Published var content: CGRect = .zero
}

/// Pebble above the front app's Dock icon (or the middle of the Dock) with a glass card: what to do, and two answers.
/// It stays until one is tapped (or the nudge is no longer due); nothing behind it changes.
@MainActor
final class NudgeCard {
    enum Content: Equatable {
        case bedtime(String)
        /// The event's key and the nudge's.
        case offtask(String, String)

        var isBedtime: Bool { if case .bedtime = self { true } else { false } }
    }

    var answered: ((Content, String) -> Void)?
    private(set) var content: Content?
    private let model = NudgeCardModel()
    private var panel: NudgePanel?
    private var pointer: Timer?
    private var leaving: Task<Void, Never>?

    private static let size = NSSize(width: 440, height: 320)

    func show(_ content: Content, title: String, body: String, mood: String, actions: [NudgeAction], above icon: NSPoint?) {
        leaving?.cancel()
        self.content = content
        model.title = title
        model.body = body
        model.mood = mood
        model.actions = actions
        model.happy = false
        model.pokes += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel, above: icon)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !model.shown { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { model.shown = true } }
        followPointer()
    }

    /// Back down into the Dock (a happy hop first after a good answer).
    func close(happy: Bool = false) {
        content = nil
        leaving?.cancel()
        leaving = Task { [weak self] in
            guard let self else { return }
            if happy {
                self.model.happy = true
                self.model.pokes += 1
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeIn(duration: 0.25)) { self.model.shown = false }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !self.model.shown else { return }
            self.panel?.orderOut(nil)
            self.pointer?.invalidate()
            self.pointer = nil
            self.model.happy = false
        }
    }

    private func tap(_ answer: String) {
        guard let content else { return }
        answered?(content, answer)
        close(happy: answer == "going" || answer == "back")
    }

    /// The panel takes clicks only over Pebble and the card.
    private func followPointer() {
        guard pointer == nil else { return }
        pointer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                let frame = panel.frame, c = self.model.content
                let rect = NSRect(x: frame.minX + c.minX, y: frame.maxY - c.maxY, width: c.width, height: c.height)
                let over = NSMouseInRect(NSEvent.mouseLocation, rect.insetBy(dx: -4, dy: -4), false)
                if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
            }
        }
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let view = NSHostingView(rootView: NudgeCardView(model: model) { [weak self] in self?.tap($0) })
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }

    private func place(_ panel: NSPanel, above icon: NSPoint?) {
        let screen = icon.flatMap { icon in NSScreen.screens.first { NSPointInRect(NSPoint(x: icon.x, y: icon.y - 1), $0.frame) } }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let x = icon?.x ?? area.midX
        let bottom = icon.map { max($0.y - 4, area.minY) } ?? area.minY
        let left = min(max(x - Self.size.width / 2, area.minX), area.maxX - Self.size.width)
        model.shift = x - (left + Self.size.width / 2)
        panel.setFrameOrigin(NSPoint(x: left, y: bottom))
    }
}

private struct NudgeCardView: View {
    @ObservedObject var model: NudgeCardModel
    let tap: (String) -> Void

    private var slide: CGFloat { max(-20, min(20, model.shift)) }

    var body: some View {
        VStack(spacing: 10) {
            card
                .scaleEffect(model.shown ? 1 : 0.8, anchor: .bottom)
                .opacity(model.shown ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(model.shown ? 0.15 : 0), value: model.shown)
            LivePebble(mood: model.happy ? "happy" : model.mood, size: 80, bounceTrigger: model.pokes)
                .foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .offset(x: model.shift - slide, y: model.shown ? 0 : 130)
        }
        .frame(width: 400)
        .padding(.top, 12)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.content = $0 }
        .offset(x: slide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .tint(Theme.accent)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.body)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .contentTransition(.opacity)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(model.actions, id: \.self) { action in
                    NudgeButton(action.label, prominent: action.prominent) { tap(action.answer) }
                }
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .modifier(StillGlass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}
