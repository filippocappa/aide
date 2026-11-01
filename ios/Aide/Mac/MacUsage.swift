import AppKit
import IOKit.pwr_mgt

/// Where this Mac's time goes, for the Screen page and the daily limits. Apple's Screen Time can't be read on the Mac,
/// so Aide counts its own (while Aide runs; it opens at login). Every few seconds the time since the last look goes to
/// one app, so the total is real time, never doubled by two screens:
/// - touched in the last minute (a key, the pointer, a scroll): the app in front, where the focus is;
/// - a video playing (an app keeping the display awake, as Safari does for a video, not for music), up to 30 minutes
///   with no input: that app, in front or not (watching on the other screen);
/// - otherwise still for up to 5 minutes (reading): the app in front, but only once you touch something again; after 5
///   minutes without, nobody was there and that stretch isn't counted.
/// Asleep, locked or away: nothing. A video playing beside the app in front also counts for the daily limits that
/// cover it (a YouTube limit catches a video on the side while you work) without adding to the total.
/// A pickup is coming back after 5 minutes or more away, put on the first app used. Kept on this Mac only, a file a day
/// in Application Support (120 days); nothing goes to the server but the limits reached.
@MainActor
final class MacUsage: ObservableObject {
    static let shared = MacUsage()

    /// Bumped each minute while counting (and at a new day), so open pages draw today again.
    @Published private(set) var revision = 0

    private struct StoredApp: Codable {
        var name: String
        var hourly: [Double] = Array(repeating: 0, count: 24)
        var pickups = 0
    }

    private struct StoredDay: Codable {
        var apps: [String: StoredApp] = [:]
        var firstPickup: Date?
        /// Each daily limit's time today, by limit id: its apps in front or playing on the side, real time once.
        var limits: [String: Double]?
    }

    /// Time held back while nobody touches anything (reading, or gone): counted once they do, dropped after 5 minutes.
    private struct Pending {
        let key: String
        let app: String
        let name: String
        let hour: Int
        var seconds: Double
        var limits: Set<Int>
    }

    private static let interval: TimeInterval = 5
    /// Touched this recently: there, focused on the app in front.
    private static let activeLimit: TimeInterval = 60
    /// Still for longer than this without a video: gone (the still stretch isn't counted).
    private static let readingLimit: TimeInterval = 5 * 60
    private static let watchingLimit: TimeInterval = 30 * 60
    private static let awayForPickup: TimeInterval = 5 * 60
    private static let kept = 120

    private let folder: URL
    private var days: [String: StoredDay] = [:]
    private var dirty = false
    private var timer: Timer?
    private var lastTick = Date()
    private var lastSave = Date()
    /// Since when nobody's been here (nil: someone is).
    private var awaySince: Date?
    private var screenAsleep = false
    private var screenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: [Pending] = []
    /// The Mac apps of each daily limit, by limit id (from `ScreenTimeService`).
    var limitApps: [Int: Set<String>] = [:]

    private init() {
        folder = URL.applicationSupportDirectory.appending(path: "Aide/usage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune()
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenAsleep = true; $0.save() }
        watch(workspace, NSWorkspace.willSleepNotification) { $0.screenAsleep = true; $0.save() }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenAsleep = false }
        watch(workspace, NSWorkspace.didWakeNotification) { $0.screenAsleep = false }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.screenLocked = true }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.screenLocked = false }
        watch(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.save() }
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        watch(NotificationCenter.default, NSApplication.willTerminateNotification) { $0.save() }
    }

    /// Starts counting (once).
    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in MacUsage.shared.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ run: @escaping (MacUsage) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in run(MacUsage.shared) }
        }
        observers.append((center, token))
    }

    // MARK: Counting

    private func tick() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), Self.interval * 2)
        lastTick = now
        defer { saveIfDue(now) }
        guard !screenAsleep, !screenLocked else { return away(now, since: now) }
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier.flatMap { Self.ignored.contains($0) ? nil : $0 }
        let idle = Self.idleSeconds()
        let playing = idle < Self.watchingLimit ? Self.playing() : [:]
        if let front, let frontID, idle < Self.activeLimit {
            commitPending()
            credit(frontID, name: front.localizedName, alongside: playing, now: now, elapsed: elapsed)
        } else if let frontID, let front, playing[frontID] != nil {
            commitPending()
            credit(frontID, name: front.localizedName, alongside: playing, now: now, elapsed: elapsed)
        } else if let (id, name) = playing.sorted(by: { $0.key < $1.key }).first {
            // Watching on the other screen, the focus left where it was.
            commitPending()
            credit(id, name: name, alongside: playing, now: now, elapsed: elapsed)
        } else if let front, let frontID, idle < Self.readingLimit {
            hold(frontID, name: front.localizedName ?? frontID, now: now, elapsed: elapsed)
        } else {
            away(now, since: now.addingTimeInterval(-idle))
        }
    }

    /// Nobody here: what was held back is dropped, and the time away runs from `since` (the last touch).
    private func away(_ now: Date, since: Date) {
        pending = []
        if awaySince == nil { awaySince = since }
    }

    /// The tick's time to an app (and the limits covering it or a video playing beside it).
    private func credit(_ id: String, name: String?, alongside playing: [String: String], now: Date,
                        elapsed: TimeInterval) {
        let key = Self.key(now)
        var day = days[key] ?? load(key)
        var app = day.apps[id] ?? StoredApp(name: name ?? id)
        if let name { app.name = name }
        app.hourly[Calendar.current.component(.hour, from: now)] += elapsed
        // Back after a while away, or the first use of the day: a pickup.
        if day.firstPickup == nil || awaySince.map({ now.timeIntervalSince($0) >= Self.awayForPickup }) == true {
            app.pickups += 1
            if day.firstPickup == nil { day.firstPickup = now.addingTimeInterval(-elapsed) }
        }
        awaySince = nil
        day.apps[id] = app
        var limits = day.limits ?? [:]
        for limit in covering(id, alongside: Set(playing.keys)) { limits[String(limit), default: 0] += elapsed }
        day.limits = limits
        days[key] = day
        dirty = true
    }

    /// Still, no video: the app in front's time waits for the next touch.
    private func hold(_ id: String, name: String, now: Date, elapsed: TimeInterval) {
        let key = Self.key(now)
        let hour = Calendar.current.component(.hour, from: now)
        if let last = pending.last, last.key == key, last.app == id, last.hour == hour {
            pending[pending.count - 1].seconds += elapsed
        } else {
            pending.append(Pending(key: key, app: id, name: name, hour: hour, seconds: elapsed,
                                   limits: covering(id, alongside: [])))
        }
    }

    /// Touched again: the still stretch was reading, and counts.
    private func commitPending() {
        guard !pending.isEmpty else { return }
        for item in pending {
            var day = days[item.key] ?? load(item.key)
            var app = day.apps[item.app] ?? StoredApp(name: item.name)
            app.hourly[item.hour] += item.seconds
            day.apps[item.app] = app
            var limits = day.limits ?? [:]
            for limit in item.limits { limits[String(limit), default: 0] += item.seconds }
            day.limits = limits
            days[item.key] = day
        }
        pending = []
        dirty = true
    }

    /// The limits whose apps are this one or a video playing beside it.
    private func covering(_ id: String, alongside playing: Set<String>) -> Set<Int> {
        Set(limitApps.filter { $0.value.contains(id) || !$0.value.isDisjoint(with: playing) }.keys)
    }

    private static let ignored: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    /// Seconds since a key, the pointer, a click or a scroll.
    private static func idleSeconds() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged,
                                    .leftMouseDragged]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// The apps keeping the display awake now (a video playing, a call), by bundle ID with their names. A helper
    /// inside an app's bundle (Chrome's) counts as the app; music only keeps the system awake, so it isn't here.
    private static func playing() -> [String: String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        let display: Set<String> = [kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                                    kIOPMAssertionTypeNoDisplaySleep as String]
        var pids: Set<pid_t> = []
        for (pid, assertions) in byPID {
            for assertion in assertions where display.contains(assertion[kIOPMAssertionTypeKey] as? String ?? "") {
                pids.insert((assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? pid.int32Value)
            }
        }
        guard !pids.isEmpty else { return [:] }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var found: [String: String] = [:]
        for pid in pids {
            let app: NSRunningApplication?
            if let own = apps.first(where: { $0.processIdentifier == pid }) {
                app = own
            } else if let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path {
                app = apps.first { $0.bundleURL.map { path.hasPrefix($0.path + "/") } == true }
            } else {
                app = nil
            }
            guard let app, let id = app.bundleIdentifier, !ignored.contains(id),
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            found[id] = app.localizedName ?? id
        }
        return found
    }

    // MARK: Reading

    /// The time this Mac spent in these apps on a day (with the focus on them).
    func seconds(on date: Date, apps: Set<String>) -> TimeInterval {
        let day = stored(Self.key(date))
        return apps.reduce(0) { sum, id in sum + (day.apps[id]?.hourly.reduce(0, +) ?? 0) }
    }

    /// A daily limit's time today: its apps in front, or a video of theirs playing on the side. Never less than the
    /// focus time alone (apps added to the limit during the day count from the morning).
    func limitSeconds(_ id: Int, apps: Set<String>, on date: Date = Date()) -> TimeInterval {
        max(stored(Self.key(date)).limits?[String(id)] ?? 0, seconds(on: date, apps: apps))
    }

    /// A day as the Screen page reads it.
    func day(_ date: Date) -> UsageDay {
        let start = Calendar.current.startOfDay(for: date)
        let stored = stored(Self.key(start))
        var day = UsageDay(date: start)
        day.firstPickup = stored.firstPickup
        day.apps = stored.apps.map { id, app in
            UsageApp(id: id, name: app.name, seconds: app.hourly.reduce(0, +), pickups: app.pickups, hourly: app.hourly)
        }
        return day
    }

    /// What the Screen page shows for a day, a week or a month, with the days it's compared with.
    func data(_ kind: UsageKind, containing date: Date, now: Date = Date()) -> UsageReportData {
        let asked = UsageMath.asked(kind, containing: date)
        let days = UsageMath.days(of: asked).filter { $0 <= now }.map(day)
        return UsageReportData(kind: kind, days: days, period: UsageMath.period(kind, containing: date))
    }

    /// Since when this Mac has been counting (the oldest day kept).
    var since: Date? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Self.formatter.date(from: String($0.dropLast(5))) }.min()
    }

    // MARK: Files

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }

    private func file(_ key: String) -> URL { folder.appending(path: "\(key).json") }

    private func stored(_ key: String) -> StoredDay {
        if let day = days[key] { return day }
        let day = load(key)
        days[key] = day
        return day
    }

    private func load(_ key: String) -> StoredDay {
        guard let data = try? Data(contentsOf: file(key)),
              let day = try? JSONDecoder().decode(StoredDay.self, from: data) else { return StoredDay() }
        return day
    }

    private func saveIfDue(_ now: Date) {
        guard now.timeIntervalSince(lastSave) >= 60 else { return }
        save()
        revision += 1
    }

    private func save() {
        lastSave = Date()
        guard dirty else { return }
        dirty = false
        let today = Self.key(Date())
        let yesterday = Self.key(Date().addingTimeInterval(-86400))
        for key in [yesterday, today] {
            guard let day = days[key], let data = try? JSONEncoder().encode(day) else { continue }
            try? data.write(to: file(key), options: .atomic)
        }
        // Only today changes: the rest are read again when asked.
        days = days.filter { $0.key >= yesterday }
    }

    private func prune() {
        let oldest = Self.key(Date().addingTimeInterval(-Double(Self.kept) * 86400))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".json") && name < oldest {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
