import DeviceActivity
import FamilyControls
import Foundation

/// Screen Time locks (docs/API.md, "Screen Time"). The server keeps the locks; this sets them on the phone: one
/// DeviceActivity schedule per lock, so the monitor extension shields and opens the apps on time with the app
/// closed, and the shield straight away for a lock that's already on. It syncs when the app opens, after a chat
/// turn and on a silent `sync` push.
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published private(set) var authorization: AuthorizationStatus
    @Published private(set) var locks: [ScreenLock] = LockBook.locks
    /// The apps and sites that stay open in a lock without its own apps (Lock now, the ones Coach sets).
    @Published var allowed: FamilyActivitySelection = LockBook.allowed {
        didSet {
            LockBook.allowed = allowed
            Task { await report() }
        }
    }
    /// The apps each lock picked for itself.
    @Published private(set) var apps: [Int: LockApps] = LockBook.apps
    @Published private(set) var lastError: String?
    @Published private(set) var passes: EmergencyPasses?
    /// Coach's line over the Screen half (what holds now or comes next), from the last sync.
    @Published private(set) var line: String?
    /// Daily app limits (docs/API.md, "Daily app limits") and the apps each counts.
    @Published private(set) var limits: [ScreenLimit] = LockBook.limits
    @Published private(set) var limitApps: [Int: FamilyActivitySelection] = LockBook.limitApps
    /// What the estimate for Coach counts (every category, picked once).
    @Published var counted: FamilyActivitySelection = LockBook.counted {
        didSet {
            LockBook.counted = counted
            var scheduled = LockBook.scheduled
            scheduled[LockBook.usageActivity.rawValue] = nil // restart it with the new pick
            LockBook.scheduled = scheduled
            apply()
        }
    }

    private let api: APIClient
    private let center = DeviceActivityCenter()

    init(api: APIClient) {
        self.api = api
        authorization = AuthorizationCenter.shared.authorizationStatus
    }

    var isAuthorized: Bool { authorization == .approved }
    var allowedCount: Int { allowed.applicationTokens.count + allowed.webDomainTokens.count }

    /// The lock on now that ends last.
    var current: (lock: ScreenLock, until: Date)? {
        locks.compactMap { lock in LockClock.until(lock).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// A strict lock on now: the Screen Time page is locked until it ends, but for an emergency pass.
    var strictOn: (lock: ScreenLock, until: Date)? {
        locks.filter(\.isStrict).compactMap { lock in LockClock.until(lock).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// A lock on now uses the usual apps: they can't change until it's over (that would be unlocking early).
    var usualInUse: Bool { locks.contains { apps[$0.id] == nil && LockClock.until($0) != nil } }

    func apps(for lock: ScreenLock) -> LockApps { apps[lock.id] ?? LockApps(only: false, selection: allowed) }

    /// A lock's own apps, or nil for the usual ones. Not for a lock that's on.
    private func setApps(_ picked: LockApps?, for id: Int) {
        let usual = LockApps(only: false, selection: allowed)
        apps[id] = picked == usual ? nil : picked
        LockBook.apps = apps
    }

    /// iOS asks once (Face ID or the passcode); after a no, only iOS Settings → Screen Time can change it.
    func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        authorization = AuthorizationCenter.shared.authorizationStatus
        apply()
        await report()
    }

    var countedCount: Int { counted.categoryTokens.count + counted.applicationTokens.count }

    /// A limit holds now: reached today, its apps locked until midnight.
    func holds(_ limit: ScreenLimit) -> Bool { LockBook.limitHolds(limit) }

    /// When the phone saw it reached today.
    func reachedAt(_ limit: ScreenLimit) -> Date? {
        guard let hit = LockBook.limitHits[limit.id], hit.date == LockBook.day() else { return nil }
        return LockClock.date(hit.at)
    }

    /// The server's locks and limits, set on the phone, after sending what the monitor saw.
    func sync() async {
        authorization = AuthorizationCenter.shared.authorizationStatus
        await upload()
        do {
            let list = try await api.locks()
            locks = list.locks
            LockBook.locks = list.locks
            passes = list.passes
            line = list.line
            if let got = list.limits {
                limits = got
                LockBook.limits = got
                // Ended early today on another device (or before a reinstall): don't lock it again today.
                var opened = LockBook.limitOpened
                for limit in got where limit.openToday { opened[limit.id] = LockBook.day() }
                LockBook.limitOpened = opened.filter { $0.value >= LockBook.day(Date().addingTimeInterval(-86400)) }
            }
            lastError = nil
            if list.device.authorized != isAuthorized || list.device.allowedApps != allowedCount { await report() }
        } catch APIError.server(404, _) {
            return // an older server, without locks
        } catch {
            lastError = error.localizedDescription
        }
        apply()
    }

    /// The last 7 days' usage steps and today's limits reached, to the server (Coach reads them).
    private func upload() async {
        let since = LockBook.day(Date().addingTimeInterval(-7 * 86400))
        let days = LockBook.usage.filter { $0.key >= since }.sorted { $0.key < $1.key }
            .map { UsageUpload.Day(date: $0.key, minutes: $0.value) }
        let hits = LockBook.limitHits.filter { $0.value.date >= since }
            .map { UsageUpload.Hit(id: $0.key, date: $0.value.date, at: $0.value.at) }
        guard !days.isEmpty || !hits.isEmpty else { return }
        try? await api.uploadUsage(UsageUpload(days: days, limits: hits))
    }

    /// Each lock's schedule watched (restarted only when it changed), the ones gone stopped, and the shields set
    /// for what holds right now; the same for the limits, and the usage estimate.
    private func apply() {
        guard isAuthorized else { return }
        var scheduled = LockBook.scheduled
        var wanted = Set<DeviceActivityName>()
        applyLimits(&scheduled, &wanted)
        for lock in locks {
            let name = LockBook.activity(lock.id)
            guard let schedule = LockBook.schedule(for: lock) else { continue }
            wanted.insert(name)
            let key = "\(lock.start ?? "")-\(lock.end ?? "")-\(lock.startsAt ?? "")-\(lock.endsAt ?? "")"
            guard scheduled[name.rawValue] != key || !center.activities.contains(name) else { continue }
            do {
                try center.startMonitoring(name, during: schedule)
                scheduled[name.rawValue] = key
            } catch {
                lastError = "Couldn't set '\(lock.title)': \(error.localizedDescription)"
            }
        }
        for name in center.activities where !wanted.contains(name)
            && (LockBook.id(of: name) != nil || LockBook.limitID(of: name.rawValue) != nil || name == LockBook.usageActivity) {
            center.stopMonitoring([name])
        }
        // A lock that's gone from the server (deleted, ended early, over) opens if it had shielded anything.
        let known = Set(locks.map(\.id))
        for key in Array(scheduled.keys) where !wanted.contains(DeviceActivityName(key)) {
            scheduled[key] = nil
            if let id = LockBook.id(of: DeviceActivityName(key)), !known.contains(id) { LockBook.open(id) }
            if let id = LockBook.limitID(of: key) { LockBook.openLimit(id) } // deleted, turned off, no apps
        }
        LockBook.scheduled = scheduled
        if apps.keys.contains(where: { !known.contains($0) }) {
            apps = apps.filter { known.contains($0.key) }
            LockBook.apps = apps
        }
        for lock in locks {
            if LockClock.until(lock) != nil { LockBook.shield(lock.id) } else { LockBook.open(lock.id) }
        }
    }

    /// A daily activity per limit with its apps (one threshold event), restarted when its minutes or apps change;
    /// the shields for what holds now. And the usage estimate's activity, once something is counted.
    private func applyLimits(_ scheduled: inout [String: String], _ wanted: inout Set<DeviceActivityName>) {
        for limit in limits {
            let name = LockBook.limitActivity(limit.id)
            guard limit.enabled, let picked = limitApps[limit.id], picked != FamilyActivitySelection() else { continue }
            wanted.insert(name)
            let key = "\(limit.minutes)"
            if scheduled[name.rawValue] != key || !center.activities.contains(name) {
                do {
                    try center.startMonitoring(name, during: LockBook.wholeDay,
                                               events: [LockBook.limitEvent(limit.id): LockBook.event(picked, minutes: limit.minutes)])
                    scheduled[name.rawValue] = key
                } catch {
                    lastError = "Couldn't set the limit '\(limit.title)': \(error.localizedDescription)"
                }
            }
            if LockBook.limitHolds(limit) { LockBook.shieldLimit(limit.id) } else { LockBook.openLimit(limit.id) }
        }
        let usage = LockBook.usageActivity
        guard counted != FamilyActivitySelection() else { return }
        wanted.insert(usage)
        guard scheduled[usage.rawValue] == nil || !center.activities.contains(usage) else { return }
        let events = Dictionary(uniqueKeysWithValues: LockBook.usageSteps.map {
            (LockBook.usageEvent($0), LockBook.event(counted, minutes: $0))
        })
        do {
            try center.startMonitoring(usage, during: LockBook.wholeDay, events: events)
            scheduled[usage.rawValue] = "on"
        } catch {
            lastError = "Couldn't start counting screen time: \(error.localizedDescription)"
        }
    }

    /// So the agents can say when a lock won't hold.
    func report() async {
        try? await api.reportScreenTime(ScreenTimeDevice(authorized: isAuthorized, allowedApps: allowedCount))
    }

    // MARK: Changes from the app

    func lockNow(minutes: Int, strict: Bool = false) async {
        await change {
            _ = try await self.api.createLock(NewLock(title: strict ? "Strict focus" : "Focus", minutes: minutes,
                                                      strict: strict ? true : nil))
        }
    }

    /// A lock that's on keeps its times and apps: only its title changes, or it becomes strict.
    func save(_ lock: ScreenLock?, title: String, start: String, end: String, days: [Int], enabled: Bool,
              strict: Bool, apps picked: LockApps) async -> Bool {
        await change {
            if let lock {
                let on = lock.locked
                _ = try await self.api.updateLock(lock.id, LockPatch(title: title, start: on ? nil : start,
                                                                     end: on ? nil : end, days: on ? nil : days,
                                                                     enabled: on ? nil : enabled,
                                                                     strict: on && !strict ? nil : strict))
                if !on { self.setApps(picked, for: lock.id) }
            } else {
                let made = try await self.api.createLock(NewLock(title: title, start: start, end: end, days: days,
                                                                 strict: strict ? true : nil))
                self.setApps(picked, for: made.id)
            }
        }
    }

    func setEnabled(_ lock: ScreenLock, _ on: Bool) async {
        await change { _ = try await self.api.updateLock(lock.id, LockPatch(enabled: on)) }
    }

    func unlock(_ lock: ScreenLock, reason: String, pass: Bool = false) async -> Bool {
        let done = await change { _ = try await self.api.unlock(lock.id, reason: reason, pass: pass) }
        if done { LockBook.open(lock.id) } // sync already did, unless the server was slow to say so
        return done
    }

    func delete(_ lock: ScreenLock) async -> Bool {
        await change { try await self.api.deleteLock(lock.id) }
    }

    // MARK: Limits from the app

    /// A limit's apps live only here. Changing them restarts its activity.
    private func setLimitApps(_ picked: FamilyActivitySelection, for id: Int) {
        limitApps[id] = picked
        LockBook.limitApps = limitApps
        var scheduled = LockBook.scheduled
        scheduled[LockBook.limitActivity(id).rawValue] = nil
        LockBook.scheduled = scheduled
    }

    func saveLimit(_ limit: ScreenLimit?, title: String, minutes: Int, days: [Int], enabled: Bool, strict: Bool,
                   apps picked: FamilyActivitySelection) async -> Bool {
        await change {
            if let limit {
                _ = try await self.api.updateLimit(limit.id, LimitPatch(title: title, minutes: minutes, days: days,
                                                                        enabled: enabled, strict: strict))
                if picked != self.limitApps[limit.id] { self.setLimitApps(picked, for: limit.id) }
            } else {
                let made = try await self.api.createLimit(NewLimit(title: title, minutes: minutes, days: days, strict: strict))
                self.setLimitApps(picked, for: made.id)
            }
        }
    }

    func setEnabled(_ limit: ScreenLimit, _ on: Bool) async {
        await change { _ = try await self.api.updateLimit(limit.id, LimitPatch(enabled: on)) }
    }

    /// Ends a limit reached today, until midnight.
    func unlock(_ limit: ScreenLimit, reason: String, pass: Bool = false) async -> Bool {
        let done = await change {
            _ = try await self.api.unlockLimit(limit.id, reason: reason, pass: pass)
            LockBook.limitOpened[limit.id] = LockBook.day()
        }
        if done { LockBook.openLimit(limit.id) }
        return done
    }

    func delete(_ limit: ScreenLimit) async -> Bool {
        let done = await change { try await self.api.deleteLimit(limit.id) }
        if done {
            limitApps[limit.id] = nil
            LockBook.limitApps = limitApps
        }
        return done
    }

    /// One change on the server, then the list again. False (with `lastError`) if the server said no.
    @discardableResult
    private func change(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        await sync()
        return true
    }
}
