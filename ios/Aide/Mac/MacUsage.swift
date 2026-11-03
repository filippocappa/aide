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
/// In Safari and the Chromium browsers the site in the front tab gets the same time too (youtube.com, only the site),
/// for the Websites list and for limits on sites; a browser Aide may not ask (or Firefox) is the app alone.
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
        /// Each website's time, by site: part of its browsers' time.
        var sites: [String: StoredSite]?
    }

    private struct StoredSite: Codable {
        var hourly: [Double] = Array(repeating: 0, count: 24)
        /// By browser bundle ID.
        var browsers: [String: Double] = [:]
    }

    /// Time held back while nobody touches anything (reading, or gone): counted once they do, dropped after 5 minutes.
    private struct Pending {
        let key: String
        let app: String
        let name: String
        let site: String?
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
    /// A tick is waiting for the browsers' tabs.
    private var readingTabs = false
    private var lastSave = Date()
    /// Since when nobody's been here (nil: someone is).
    private var awaySince: Date?
    private var screenAsleep = false
    private var screenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: [Pending] = []
    /// The Mac apps of each daily limit, by limit id (from `ScreenTimeService`).
    var limitApps: [Int: Set<String>] = [:]
    /// Each tick, the browsers' tabs seen (the one in front, those playing a video), for the shield.
    var onTabs: (([MacBrowser.Tab]) -> Void)?

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
        guard !readingTabs else { return }  // the last tick's browsers haven't answered: its time comes next tick
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), Self.interval * 2)
        lastTick = now
        guard !screenAsleep, !screenLocked else {
            away(now, since: now)
            return saveIfDue(now)
        }
        let front = NSWorkspace.shared.frontmostApplication
        let idle = Self.idleSeconds()
        let playing = idle < Self.watchingLimit ? Self.playing() : [:]
        guard idle < Self.watchingLimit else {
            return count(now: now, elapsed: elapsed, front: front, idle: idle, playing: playing, tabs: [:])
        }
        // The browsers answer off the main thread; the tick is counted when they have.
        readingTabs = true
        Task {
            let tabs = await Self.tabs(front: front, playing: Set(playing.keys))
            readingTabs = false
            count(now: now, elapsed: elapsed, front: front, idle: idle, playing: playing, tabs: tabs)
        }
    }

    private func count(now: Date, elapsed: TimeInterval, front: NSRunningApplication?, idle: TimeInterval,
                       playing: [String: String], tabs: [String: MacBrowser.Tab]) {
        defer { saveIfDue(now) }
        let frontID = front?.bundleIdentifier.flatMap { Self.ignored.contains($0) ? nil : $0 }
        onTabs?(Array(tabs.values))
        // What plays on the side, for the limits: the apps and their sites.
        let alongside = Set(playing.keys).union(playing.keys.compactMap { tabs[$0].map { MacSites.entry($0.site) } })
        if let front, let frontID, idle < Self.activeLimit {
            commitPending()
            credit(frontID, name: front.localizedName, site: tabs[frontID]?.site, alongside: alongside, now: now,
                   elapsed: elapsed)
        } else if let frontID, let front, playing[frontID] != nil {
            commitPending()
            credit(frontID, name: front.localizedName, site: tabs[frontID]?.site, alongside: alongside, now: now,
                   elapsed: elapsed)
        } else if let (id, name) = playing.sorted(by: { $0.key < $1.key }).first {
            // Watching on the other screen, the focus left where it was.
            commitPending()
            credit(id, name: name, site: tabs[id]?.site, alongside: alongside, now: now, elapsed: elapsed)
        } else if let front, let frontID, idle < Self.readingLimit {
            hold(frontID, name: front.localizedName ?? frontID, site: tabs[frontID]?.site, now: now, elapsed: elapsed)
        } else {
            away(now, since: now.addingTimeInterval(-idle))
        }
    }

    /// Nobody here: what was held back is dropped, and the time away runs from `since` (the last touch).
    private func away(_ now: Date, since: Date) {
        pending = []
        if awaySince == nil { awaySince = since }
    }

    /// The browsers' front tabs: the app in front's, and those of the apps playing a video.
    private static func tabs(front: NSRunningApplication?, playing: Set<String>) async -> [String: MacBrowser.Tab] {
        var apps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map { playing.contains($0) && MacBrowser.isBrowser($0) } == true
        }
        if let front, front.bundleIdentifier.map(MacBrowser.isBrowser) == true, !apps.contains(front) {
            apps.append(front)
        }
        var tabs: [String: MacBrowser.Tab] = [:]
        for app in apps { if let tab = await MacBrowser.tab(of: app) { tabs[tab.app] = tab } }
        return tabs
    }

    /// The tick's time to an app and its site (and the limits covering them or a video playing beside them).
    private func credit(_ id: String, name: String?, site: String?, alongside: Set<String>, now: Date,
                        elapsed: TimeInterval) {
        let key = Self.key(now)
        let hour = Calendar.current.component(.hour, from: now)
        var day = days[key] ?? load(key)
        var app = day.apps[id] ?? StoredApp(name: name ?? id)
        if let name { app.name = name }
        app.hourly[hour] += elapsed
        if let site { add(site, browser: id, hour: hour, seconds: elapsed, to: &day) }
        // Back after a while away, or the first use of the day: a pickup.
        if day.firstPickup == nil || awaySince.map({ now.timeIntervalSince($0) >= Self.awayForPickup }) == true {
            app.pickups += 1
            if day.firstPickup == nil { day.firstPickup = now.addingTimeInterval(-elapsed) }
        }
        awaySince = nil
        day.apps[id] = app
        var limits = day.limits ?? [:]
        for limit in covering(Self.entries(id, site), alongside: alongside) {
            limits[String(limit), default: 0] += elapsed
        }
        day.limits = limits
        days[key] = day
        dirty = true
    }

    /// Still, no video: the app in front's time waits for the next touch.
    private func hold(_ id: String, name: String, site: String?, now: Date, elapsed: TimeInterval) {
        let key = Self.key(now)
        let hour = Calendar.current.component(.hour, from: now)
        if let last = pending.last, last.key == key, last.app == id, last.site == site, last.hour == hour {
            pending[pending.count - 1].seconds += elapsed
        } else {
            pending.append(Pending(key: key, app: id, name: name, site: site, hour: hour, seconds: elapsed,
                                   limits: covering(Self.entries(id, site), alongside: [])))
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
            if let site = item.site { add(site, browser: item.app, hour: item.hour, seconds: item.seconds, to: &day) }
            var limits = day.limits ?? [:]
            for limit in item.limits { limits[String(limit), default: 0] += item.seconds }
            day.limits = limits
            days[item.key] = day
        }
        pending = []
        dirty = true
    }

    private func add(_ site: String, browser: String, hour: Int, seconds: Double, to day: inout StoredDay) {
        var sites = day.sites ?? [:]
        var stored = sites[site] ?? StoredSite()
        stored.hourly[hour] += seconds
        stored.browsers[browser, default: 0] += seconds
        sites[site] = stored
        day.sites = sites
    }

    /// An app and its site, as limits list them.
    private static func entries(_ id: String, _ site: String?) -> Set<String> {
        Set([id] + [site.map(MacSites.entry)].compactMap { $0 })
    }

    /// The limits covering these apps or sites, or a video playing beside them (its app or site).
    private func covering(_ entries: Set<String>, alongside: Set<String>) -> Set<Int> {
        let all = entries.union(alongside)
        return Set(limitApps.filter { limit in all.contains { MacSites.covers(limit.value, $0) } }.keys)
    }

    private static let ignored: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
                                                         "com.apple.SecurityAgent"]

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

    /// The time this Mac spent in these apps and sites on a day (with the focus on them); a site's time in a browser
    /// that's on the list too is counted once.
    func seconds(on date: Date, apps: Set<String>) -> TimeInterval {
        let day = stored(Self.key(date))
        let inApps = apps.reduce(0) { sum, id in sum + (day.apps[id]?.hourly.reduce(0, +) ?? 0) }
        let inSites = (day.sites ?? [:]).filter { MacSites.covers(apps, MacSites.entry($0.key)) }.values
            .reduce(0) { sum, site in sum + site.browsers.filter { !apps.contains($0.key) }.values.reduce(0, +) }
        return inApps + inSites
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
        day.apps = stored.apps.filter { !Self.ignored.contains($0.key) }.map { id, app in
            UsageApp(id: id, name: app.name, seconds: app.hourly.reduce(0, +), pickups: app.pickups, hourly: app.hourly)
        }
        day.sites = (stored.sites ?? [:]).map { site, stored in
            UsageSite(id: site, seconds: stored.hourly.reduce(0, +), hourly: stored.hourly, browsers: stored.browsers)
        }.filter { $0.seconds >= 1 }.sorted { $0.seconds > $1.seconds }
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
