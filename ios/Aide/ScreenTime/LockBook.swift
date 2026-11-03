import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// The apps a lock covers: only `selection` (social apps while studying), or everything but it (bedtime). Its
/// tokens only mean something on this phone, so the server never sees them.
struct LockApps: Codable, Equatable {
    var only: Bool
    var selection: FamilyActivitySelection

    /// "Everything but 3 apps", "4 apps and 1 category". Whole categories can't be kept open, only apps.
    var text: String {
        let apps = selection.applicationTokens.count + selection.webDomainTokens.count
        let categories = selection.categoryTokens.count
        let appsText = "\(apps) app\(apps == 1 ? "" : "s")"
        if !only { return apps == 0 ? "Everything" : "Everything but \(appsText)" }
        let parts = [apps > 0 ? appsText : nil,
                     categories > 0 ? "\(categories) categor\(categories == 1 ? "y" : "ies")" : nil].compactMap { $0 }
        return parts.isEmpty ? "Nothing picked" : parts.joined(separator: " and ")
    }
}

/// The locks and limits and what they let through, kept in the App Group so the monitor and shield extensions read
/// them with the app closed. The app writes them; the monitor writes only what it saw (limits reached, the day's
/// usage steps). Each lock and limit shields through its own named store, so two that overlap don't undo each other
/// when one ends.
enum LockBook {
    private static let defaults: UserDefaults? = (Bundle.main.object(forInfoDictionaryKey: "AideAppGroup") as? String)
        .flatMap { $0.isEmpty || $0.contains("$(") ? nil : UserDefaults(suiteName: $0) }

    static var locks: [ScreenLock] {
        get { defaults?.data(forKey: "screenLocks").flatMap { try? JSONDecoder().decode([ScreenLock].self, from: $0) } ?? [] }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenLocks") }
    }

    /// The apps and sites that stay open in a lock. Its tokens only mean something on this phone.
    static var allowed: FamilyActivitySelection {
        get {
            defaults?.data(forKey: "screenAllowed").flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
                ?? FamilyActivitySelection()
        }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenAllowed") }
    }

    /// The apps each lock picked for itself, by lock id. A lock without its own locks everything but `allowed`.
    static var apps: [Int: LockApps] {
        get {
            let stored = defaults?.data(forKey: "screenApps").flatMap { try? JSONDecoder().decode([String: LockApps].self, from: $0) }
            return Dictionary(uniqueKeysWithValues: (stored ?? [:]).compactMap { key, value in Int(key).map { ($0, value) } })
        }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            defaults?.set(try? JSONEncoder().encode(stored), forKey: "screenApps")
        }
    }

    /// The apps and sites that stay open in a focus round (Aide for the Study page, Notes, Files…). Until picked, the
    /// usual `allowed` ones.
    static var focusAllowed: FamilyActivitySelection {
        get {
            defaults?.data(forKey: "screenFocusAllowed").flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
                ?? allowed
        }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenFocusAllowed") }
    }

    /// What a lock covers: a focus round everything but the focus apps, else the lock's own pick or everything but
    /// the usual ones.
    static func apps(for id: Int) -> LockApps {
        if locks.first(where: { $0.id == id })?.focus != nil { return LockApps(only: false, selection: focusAllowed) }
        return apps[id] ?? LockApps(only: false, selection: allowed)
    }

    /// What each lock was last scheduled with, so a sync only restarts the ones that changed.
    static var scheduled: [String: String] {
        get { defaults?.dictionary(forKey: "screenScheduled") as? [String: String] ?? [:] }
        set { defaults?.set(newValue, forKey: "screenScheduled") }
    }

    // MARK: Daily limits and the usage estimate (docs/API.md, "Daily app limits", "Screen time estimates")

    static var limits: [ScreenLimit] {
        get { defaults?.data(forKey: "screenLimits").flatMap { try? JSONDecoder().decode([ScreenLimit].self, from: $0) } ?? [] }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenLimits") }
    }

    /// The apps each limit counts and locks, by limit id.
    static var limitApps: [Int: FamilyActivitySelection] {
        get { intKeyed("screenLimitApps") }
        set { setIntKeyed(newValue, "screenLimitApps") }
    }

    /// The day (local, YYYY-MM-DD) each limit was ended early, so the monitor doesn't lock it again that day.
    static var limitOpened: [Int: String] {
        get { intKeyed("screenLimitOpened") }
        set { setIntKeyed(newValue, "screenLimitOpened") }
    }

    /// A limit reached: the day (local) and when (ISO). Written by the monitor, sent to the server on sync.
    struct Hit: Codable, Equatable {
        let date: String
        let at: String
    }

    static var limitHits: [Int: Hit] {
        get { intKeyed("screenLimitHits") }
        set { setIntKeyed(newValue, "screenLimitHits") }
    }

    /// The highest 15-minute step of screen time reached each day (local date: minutes). Written by the monitor.
    static var usage: [String: Int] {
        get { defaults?.dictionary(forKey: "screenUsage") as? [String: Int] ?? [:] }
        set { defaults?.set(newValue, forKey: "screenUsage") }
    }

    /// What the usage estimate counts: the user picks every category once ("Share with Coach").
    static var counted: FamilyActivitySelection {
        get {
            defaults?.data(forKey: "screenCounted").flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
                ?? FamilyActivitySelection()
        }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenCounted") }
    }

    private static func intKeyed<T: Codable>(_ key: String) -> [Int: T] {
        let stored = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([String: T].self, from: $0) }
        return Dictionary(uniqueKeysWithValues: (stored ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
    }

    private static func setIntKeyed<T: Codable>(_ value: [Int: T], _ key: String) {
        defaults?.set(try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: value.map { (String($0.key), $0.value) })),
                      forKey: key)
    }

    static func day(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let usageActivity = DeviceActivityName("usage")

    /// The steps the usage estimate watches: every 15 minutes to 8 hours, then every hour to 16.
    static let usageSteps: [Int] = Array(stride(from: 15, through: 480, by: 15)) + Array(stride(from: 540, through: 960, by: 60))

    static func usageEvent(_ minutes: Int) -> DeviceActivityEvent.Name { .init("usage-\(minutes)") }

    static func usageMinutes(of event: DeviceActivityEvent.Name) -> Int? {
        event.rawValue.hasPrefix("usage-") ? Int(event.rawValue.dropFirst(6)) : nil
    }

    static func limitActivity(_ id: Int) -> DeviceActivityName { DeviceActivityName("limit-\(id)") }
    static func limitEvent(_ id: Int) -> DeviceActivityEvent.Name { .init("limit-\(id)") }

    static func limitID(of name: String) -> Int? {
        name.hasPrefix("limit-") ? Int(name.dropFirst(6)) : nil
    }

    /// The whole day, every day: a limit or the estimate counts from midnight (the monitor checks a limit's days).
    static let wholeDay = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                                 intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)

    /// `minutes` of use of `selection`, counting what was used earlier the same day too.
    static func event(_ selection: FamilyActivitySelection, minutes: Int) -> DeviceActivityEvent {
        let threshold = DateComponents(hour: minutes / 60, minute: minutes % 60)
        if #available(iOS 17.4, *) {
            return DeviceActivityEvent(applications: selection.applicationTokens, categories: selection.categoryTokens,
                                       webDomains: selection.webDomainTokens, threshold: threshold,
                                       includesPastActivity: true)
        }
        return DeviceActivityEvent(applications: selection.applicationTokens, categories: selection.categoryTokens,
                                   webDomains: selection.webDomainTokens, threshold: threshold)
    }

    /// Whether a limit holds now: reached today (the monitor saw it), counting today, not ended early today. Only
    /// what this phone wrote: the server's `reachedToday` and `openToday` may be from yesterday.
    static func limitHolds(_ limit: ScreenLimit, at now: Date = Date()) -> Bool {
        let today = day(now)
        return limitHits[limit.id]?.date == today && limit.counts(on: now) && limitOpened[limit.id] != today
    }

    private static func limitStore(_ id: Int) -> ManagedSettingsStore { ManagedSettingsStore(named: .init("limit-\(id)")) }

    /// Lock a limit's apps, until midnight (the monitor opens them when the day starts again).
    static func shieldLimit(_ id: Int) {
        let picked = limitApps[id] ?? FamilyActivitySelection()
        let store = limitStore(id)
        store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
        store.shield.webDomains = picked.webDomainTokens.isEmpty ? nil : picked.webDomainTokens
        store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        store.shield.webDomainCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
    }

    static func openLimit(_ id: Int) {
        limitStore(id).clearAllSettings()
    }

    /// The limit whose apps include this one (for the shield's words), else any that holds now.
    static func limitHolding(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                             domain: WebDomainToken? = nil) -> ScreenLimit? {
        let holding = limits.filter { limitHolds($0) }
        return holding.first { limit in
            let picked = limitApps[limit.id] ?? FamilyActivitySelection()
            return app.map(picked.applicationTokens.contains) == true || category.map(picked.categoryTokens.contains) == true
                || domain.map(picked.webDomainTokens.contains) == true
        } ?? holding.first
    }

    static func activity(_ id: Int) -> DeviceActivityName { DeviceActivityName("lock-\(id)") }

    static func id(of activity: DeviceActivityName) -> Int? {
        activity.rawValue.hasPrefix("lock-") ? Int(activity.rawValue.dropFirst(5)) : nil
    }

    private static func store(_ id: Int) -> ManagedSettingsStore { ManagedSettingsStore(named: .init("lock-\(id)")) }

    /// Shield what the lock covers: only its apps, or everything but them.
    static func shield(_ id: Int) {
        let apps = apps(for: id)
        let picked = apps.selection
        let store = store(id)
        if apps.only {
            store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
            store.shield.webDomains = picked.webDomainTokens.isEmpty ? nil : picked.webDomainTokens
            store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
            store.shield.webDomainCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        } else {
            store.shield.applications = nil
            store.shield.webDomains = nil
            store.shield.applicationCategories = .all(except: picked.applicationTokens)
            store.shield.webDomainCategories = .all(except: picked.webDomainTokens)
        }
    }

    static func open(_ id: Int) {
        store(id).clearAllSettings()
    }

    // MARK: When (the maths is LockClock's, shared with the Mac)

    /// The lock that holds now and ends last: the one the shield names.
    static func current(at now: Date = Date()) -> (lock: ScreenLock, until: Date)? { LockClock.current(locks, at: now) }

    /// The schedule DeviceActivity watches for a lock: daily for a schedule (the monitor checks the day), the exact
    /// times for a one-off. nil: nothing to watch (a schedule that's off, a one-off that's over).
    static func schedule(for lock: ScreenLock, now: Date = Date()) -> DeviceActivitySchedule? {
        if lock.once {
            guard let start = LockClock.date(lock.startsAt), let end = LockClock.date(lock.endsAt), end > now else { return nil }
            let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            return DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(fields, from: max(start, now)),
                                          intervalEnd: Calendar.current.dateComponents(fields, from: end), repeats: false)
        }
        guard lock.enabled, let start = LockClock.minutes(lock.start), let end = LockClock.minutes(lock.end) else { return nil }
        return DeviceActivitySchedule(intervalStart: DateComponents(hour: start / 60, minute: start % 60),
                                      intervalEnd: DateComponents(hour: end / 60, minute: end % 60), repeats: true)
    }
}
