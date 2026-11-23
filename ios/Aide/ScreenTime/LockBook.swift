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
        let lock = locks.first { $0.id == id }
        if lock?.focus != nil { return LockApps(only: false, selection: focusAllowed) }
        // A list this phone has picked; one it hasn't falls back to the lock's own apps, so it never opens anything.
        if let list = lock?.list, let picked = listApps[list], picked != FamilyActivitySelection() {
            return LockApps(only: true, selection: picked)
        }
        return apps[id] ?? LockApps(only: false, selection: allowed)
    }

    // MARK: App lists (docs/API.md, "App lists")

    static var lists: [ScreenList] {
        get { defaults?.data(forKey: "screenLists").flatMap { try? JSONDecoder().decode([ScreenList].self, from: $0) } ?? [] }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenLists") }
    }

    /// This phone's pick of each list, by list id.
    static var listApps: [Int: FamilyActivitySelection] {
        get { intKeyed("screenListApps") }
        set { setIntKeyed(newValue, "screenListApps") }
    }

    /// What a limit counts: its list's apps (none until the list is picked here), else its own.
    static func limitSelection(_ id: Int) -> FamilyActivitySelection {
        if let list = limits.first(where: { $0.id == id })?.list { return listApps[list] ?? FamilyActivitySelection() }
        return limitApps[id] ?? FamilyActivitySelection()
    }

    /// The selection covers the app, site or category.
    static func covers(_ picked: FamilyActivitySelection, app: ApplicationToken?, category: ActivityCategoryToken?,
                       domain: WebDomainToken?) -> Bool {
        app.map(picked.applicationTokens.contains) == true || category.map(picked.categoryTokens.contains) == true
            || domain.map(picked.webDomainTokens.contains) == true
    }

    // MARK: Rations (docs/API.md, "Rations")

    /// The server's rations, as of the last sync, and the local day that was.
    static var rations: [ScreenRation] {
        get { defaults?.data(forKey: "screenRations").flatMap { try? JSONDecoder().decode([ScreenRation].self, from: $0) } ?? [] }
        set {
            defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenRations")
            defaults?.set(day(), forKey: "screenRationsDay")
        }
    }

    private static var rationsDay: String? { defaults?.string(forKey: "screenRationsDay") }

    /// A ration's own pick, when it has no list.
    static var rationApps: [Int: FamilyActivitySelection] {
        get { intKeyed("screenRationApps") }
        set { setIntKeyed(newValue, "screenRationApps") }
    }

    static func rationSelection(_ ration: ScreenRation) -> FamilyActivitySelection {
        if let list = ration.list { return listApps[list] ?? FamilyActivitySelection() }
        return rationApps[ration.id] ?? FamilyActivitySelection()
    }

    /// An open spent on this phone. `counted`: the server's numbers (`rations`) include it.
    struct RationOpen: Codable, Equatable {
        let ration: Int
        let key: String
        let at: String
        let date: String
        var sent = false
        var counted = false
    }

    static var rationOpens: [RationOpen] {
        get { defaults?.data(forKey: "screenRationOpens").flatMap { try? JSONDecoder().decode([RationOpen].self, from: $0) } ?? [] }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "screenRationOpens") }
    }

    /// The open going on now, per ration: it ends at this time unless the app is used again before.
    static var rationOpenUntil: [Int: Date] {
        get { intKeyed("screenRationOpenUntil") }
        set { setIntKeyed(newValue, "screenRationOpenUntil") }
    }

    /// Today's opens left: the server's count at the last sync (every device's), less the ones spent here since.
    static func opensLeft(_ ration: ScreenRation, at now: Date = Date()) -> Int {
        let today = day(now)
        let server = rationsDay == today ? ration.usedToday : 0
        let here = rationOpens.filter { $0.ration == ration.id && $0.date == today && !$0.counted }.count
        return max(ration.opens - server - here, 0)
    }

    static func rationInUse(_ id: Int, at now: Date = Date()) -> Bool { (rationOpenUntil[id] ?? .distantPast) > now }

    /// Locked now: on, with apps picked here, and no open going on.
    static func rationHolds(_ ration: ScreenRation, at now: Date = Date()) -> Bool {
        ration.enabled && rationSelection(ration) != FamilyActivitySelection() && !rationInUse(ration.id, at: now)
    }

    /// The ration that has this app locked now, for the shield's words and its Open button.
    static func rationHolding(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                              domain: WebDomainToken? = nil) -> ScreenRation? {
        rations.first { rationHolds($0) && covers(rationSelection($0), app: app, category: category, domain: domain) }
    }

    private static func rationStore(_ id: Int) -> ManagedSettingsStore { ManagedSettingsStore(named: .init("ration-\(id)")) }

    static func shieldRation(_ ration: ScreenRation) {
        let picked = rationSelection(ration)
        let store = rationStore(ration.id)
        store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
        store.shield.webDomains = picked.webDomainTokens.isEmpty ? nil : picked.webDomainTokens
        store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        store.shield.webDomainCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
    }

    static func openRationStore(_ id: Int) { rationStore(id).clearAllSettings() }

    static func rationActivity(_ id: Int) -> DeviceActivityName { DeviceActivityName("ration-\(id)") }
    static func rationEvent(_ id: Int) -> DeviceActivityEvent.Name { .init("ration-\(id)") }
    static func rationID(of name: String) -> Int? { name.hasPrefix("ration-") ? Int(name.dropFirst(7)) : nil }

    /// Spends one of today's opens (the shield's Open): the apps open, and stay open while they're used. False when
    /// none are left.
    @discardableResult
    static func startRationOpen(_ id: Int, at now: Date = Date()) -> Bool {
        guard let ration = rations.first(where: { $0.id == id }), ration.enabled, opensLeft(ration, at: now) > 0 else { return false }
        var opens = rationOpens.filter { $0.date >= day(now.addingTimeInterval(-2 * 86400)) }
        opens.append(RationOpen(ration: id, key: UUID().uuidString, at: ISO8601DateFormatter().string(from: now), date: day(now)))
        rationOpens = opens
        keepRationOpen(ration, at: now)
        openRationStore(id)
        return true
    }

    /// The open goes on for `gap` minutes more: watched again with a one-minute-of-use event, so each minute the
    /// apps are used pushes the end on, and the interval's end (no use for `gap` minutes) locks them again. The
    /// interval starts in the past, as DeviceActivity wants 15 minutes at least.
    static func keepRationOpen(_ ration: ScreenRation, at now: Date = Date()) {
        let until = now.addingTimeInterval(Double(ration.gap) * 60)
        var open = rationOpenUntil
        open[ration.id] = until
        rationOpenUntil = open
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let start = min(now, until.addingTimeInterval(-15 * 60 - 30))
        let schedule = DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(fields, from: start),
                                              intervalEnd: Calendar.current.dateComponents(fields, from: until),
                                              repeats: false)
        let picked = rationSelection(ration)
        let event: DeviceActivityEvent
        if #available(iOS 17.4, *) {
            event = DeviceActivityEvent(applications: picked.applicationTokens, categories: picked.categoryTokens,
                                        webDomains: picked.webDomainTokens, threshold: DateComponents(minute: 1),
                                        includesPastActivity: false)
        } else {
            event = DeviceActivityEvent(applications: picked.applicationTokens, categories: picked.categoryTokens,
                                        webDomains: picked.webDomainTokens, threshold: DateComponents(minute: 1))
        }
        let center = DeviceActivityCenter()
        center.stopMonitoring([rationActivity(ration.id)])
        try? center.startMonitoring(rationActivity(ration.id), during: schedule, events: [rationEvent(ration.id): event])
    }

    /// The open is over (unused for `gap` minutes): locked again.
    static func endRationOpen(_ id: Int, at now: Date = Date()) {
        guard let until = rationOpenUntil[id], until <= now.addingTimeInterval(15) else { return }
        var open = rationOpenUntil
        open[id] = nil
        rationOpenUntil = open
        DeviceActivityCenter().stopMonitoring([rationActivity(id)])
        if let ration = rations.first(where: { $0.id == id }), rationHolds(ration, at: now) { shieldRation(ration) }
    }

    // MARK: A Focus filter (Work): the list it blocks while that Focus is on

    static var focusFilterList: Int? {
        get { (defaults?.object(forKey: "screenFocusFilterList") as? Int) }
        set { defaults?.set(newValue, forKey: "screenFocusFilterList") }
    }

    private static var focusFilterStore: ManagedSettingsStore { ManagedSettingsStore(named: .init("focus-filter")) }

    /// Shield the Focus filter's list, or nothing when no Focus asks for one.
    static func applyFocusFilter() {
        guard let list = focusFilterList, let picked = listApps[list], picked != FamilyActivitySelection() else {
            focusFilterStore.clearAllSettings()
            return
        }
        let store = focusFilterStore
        store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
        store.shield.webDomains = picked.webDomainTokens.isEmpty ? nil : picked.webDomainTokens
        store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        store.shield.webDomainCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
    }

    /// The Focus filter's list, if it covers this app now.
    static func focusFilterHolding(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                                   domain: WebDomainToken? = nil) -> ScreenList? {
        guard let id = focusFilterList, let picked = listApps[id],
              covers(picked, app: app, category: category, domain: domain) else { return nil }
        return lists.first { $0.id == id } ?? ScreenList(id: id, name: "Focus", mac: [])
    }

    /// A lock holding now that covers this app (its own "only" apps, or everything but the ones it keeps open).
    static func lockHolding(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                            domain: WebDomainToken? = nil, at now: Date = Date()) -> (lock: ScreenLock, until: Date)? {
        locks.compactMap { lock -> (ScreenLock, Date)? in
            guard let until = LockClock.until(lock, at: now) else { return nil }
            let apps = apps(for: lock.id)
            let inIt = covers(apps.selection, app: app, category: category, domain: domain)
            return apps.only == inIt ? (lock, until) : nil
        }.max { $0.1 < $1.1 }
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
        let picked = limitSelection(id)
        let store = limitStore(id)
        store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
        store.shield.webDomains = picked.webDomainTokens.isEmpty ? nil : picked.webDomainTokens
        store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        store.shield.webDomainCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
    }

    static func openLimit(_ id: Int) {
        limitStore(id).clearAllSettings()
    }

    /// The limit used up now whose apps include this one, for the shield's words.
    static func limitHolding(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                             domain: WebDomainToken? = nil) -> ScreenLimit? {
        limits.filter { limitHolds($0) }.first { covers(limitSelection($0.id), app: app, category: category, domain: domain) }
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
