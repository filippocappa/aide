import AppKit
import IOKit.pwr_mgt

/// Where this Mac's time goes, for the Screen page and the daily limits. Apple's Screen Time can't be read on the Mac,
/// so Aide counts its own: every few seconds the app in front gets the time since the last look, while someone is
/// there (the screen awake and unlocked, a key or the pointer touched in the last 2 minutes, or up to 30 while the app
/// in front keeps the display awake, as a video does). A pickup is coming back after 5 minutes or more away, put on the
/// first app used. Kept on this Mac only, a file a day in Application Support (120 days); nothing goes to the server
/// but the limits reached.
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
    }

    private static let interval: TimeInterval = 5
    private static let idleLimit: TimeInterval = 120
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
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, let id = front.bundleIdentifier, isHere(front) else {
            if awaySince == nil { awaySince = now }
            saveIfDue(now)
            return
        }
        guard id != "com.apple.loginwindow", id != "com.apple.ScreenSaver.Engine" else { return }
        let key = Self.key(now)
        var day = days[key] ?? load(key)
        var app = day.apps[id] ?? StoredApp(name: front.localizedName ?? id)
        if let name = front.localizedName { app.name = name }
        let hour = Calendar.current.component(.hour, from: now)
        app.hourly[hour] += elapsed
        // Back after a while away, or the first use of the day: a pickup.
        if day.firstPickup == nil || awaySince.map({ now.timeIntervalSince($0) >= Self.awayForPickup }) == true {
            app.pickups += 1
            if day.firstPickup == nil { day.firstPickup = now.addingTimeInterval(-elapsed) }
        }
        awaySince = nil
        day.apps[id] = app
        days[key] = day
        dirty = true
        saveIfDue(now)
    }

    /// Someone is using the Mac, with this app in front.
    private func isHere(_ front: NSRunningApplication) -> Bool {
        guard !screenAsleep, !screenLocked else { return false }
        let idle = Self.idleSeconds()
        if idle < Self.idleLimit { return true }
        return idle < Self.watchingLimit && Self.keepsDisplayAwake(front)
    }

    /// Seconds since a key, the pointer, a click or a scroll.
    private static func idleSeconds() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged,
                                    .leftMouseDragged]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// The app (or a helper inside its bundle) is holding the display awake: a video playing, a call.
    private static func keepsDisplayAwake(_ app: NSRunningApplication) -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let bundle = app.bundleURL?.path
        for (pid, assertions) in byPID {
            guard assertions.contains(where: {
                let type = $0[kIOPMAssertionTypeKey] as? String
                return type == kIOPMAssertionTypePreventUserIdleDisplaySleep as String
                    || type == kIOPMAssertionTypeNoDisplaySleep as String
            }) else { continue }
            if pid.int32Value == app.processIdentifier { return true }
            if let bundle, let other = NSRunningApplication(processIdentifier: pid.int32Value)?.bundleURL?.path,
               other.hasPrefix(bundle + "/") { return true }
        }
        return false
    }

    // MARK: Reading

    /// The time this Mac spent in these apps on a day.
    func seconds(on date: Date, apps: Set<String>) -> TimeInterval {
        let day = stored(Self.key(date))
        return apps.reduce(0) { sum, id in sum + (day.apps[id]?.hourly.reduce(0, +) ?? 0) }
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
