import AppKit
import Foundation

/// Screen Time locks on the Mac (docs/API.md, "Screen Time"; issue #30). Apple's Screen Time API is iOS-only, so
/// Aide enforces the locks itself: the same locks as the phone, read from the server and worked out here
/// (`LockClock`), so a lock starts and ends on time without asking the server again. The Mac gets no silent pushes,
/// so it fetches on open and after a chat turn (`AppEnvironment`, as the phone does), every minute while running, and
/// when the Mac wakes. What a lock covers is the Mac's own (apps by bundle ID, kept on this Mac, never on the server);
/// `MacShield` covers them while a lock holds.
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published private(set) var locks: [ScreenLock] = []
    @Published private(set) var passes: EmergencyPasses?
    @Published private(set) var lastError: String?
    /// The lock on now that ends last, recomputed at every start and end.
    @Published private(set) var current: (lock: ScreenLock, until: Date)?
    /// A strict lock on now: only an emergency pass ends it early, and Quit is refused.
    @Published private(set) var strictOn: (lock: ScreenLock, until: Date)?
    /// The apps a lock without its own covers (Lock now, the ones Coach sets), by bundle ID. Unlike the phone's
    /// "everything but these", the Mac's are "only these": a lock that blocks everything blocks the work too.
    @Published private(set) var usualApps: Set<String> = MacLockApps.usual
    /// The apps each lock picked for itself, by lock id.
    @Published private(set) var lockApps: [Int: Set<String>] = MacLockApps.perLock
    /// Daily app limits (docs/API.md, "Daily app limits"), the same as the phone's. Each device counts its own time:
    /// here, the time this Mac spent in the limit's Mac apps (`MacUsage`).
    @Published private(set) var limits: [ScreenLimit] = []
    /// The Mac apps each limit counts, by limit id. None: the limit does nothing on this Mac.
    @Published private(set) var limitApps: [Int: Set<String>] = MacLockApps.perLimit {
        didSet { MacUsage.shared.limitApps = limitApps }
    }
    /// The limits holding now on this Mac: reached here today, not ended early.
    @Published private(set) var heldLimits: Set<Int> = []
    private var limitHits: [Int: MacLimitHit] = MacLockApps.limitHits
    private var limitOpened: [Int: String] = [:]

    private let api: APIClient
    private var poll: Task<Void, Never>?
    private var nextTick: Task<Void, Never>?
    private var limitCheck: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(api: APIClient) {
        self.api = api
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sync()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in await self?.sync() }
        })
        MacUsage.shared.limitApps = limitApps
        MacUsage.shared.start()
        limitCheck = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkLimits()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        if !testLocks.isEmpty {
            locks = testLocks
            tick()
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.tick() }
            })
        }
    }

    /// Nothing to allow on the Mac: Aide enforces the locks itself.
    var isAuthorized: Bool { true }

    func apps(for lock: ScreenLock) -> Set<String> {
        #if DEBUG
        if lock.id < 0, let test = UserDefaults.standard.string(forKey: "shieldApps") {
            return Set(test.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        #endif
        return lockApps[lock.id] ?? usualApps
    }

    /// The lock or limit that covers an app now (the one that ends last), or nil: the app is free.
    func covering(_ bundleID: String?) -> MacHold? {
        guard let bundleID, !MacLockApps.never.contains(bundleID) else { return nil }
        let now = Date()
        let byLocks = locks.filter { MacSites.covers(apps(for: $0), bundleID) }
            .compactMap { lock in LockClock.until(lock, at: now).map { MacHold(lock: lock, until: $0) } }
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 + 3600)
        let byLimits = limits.filter { heldLimits.contains($0.id) && MacSites.covers(limitApps[$0.id] ?? [], bundleID) }
            .map { MacHold(limit: $0, until: Calendar.current.startOfDay(for: midnight)) }
        return (byLocks + byLimits).max { $0.until < $1.until }
    }

    /// The usual apps. Not while a lock that uses them is on: that would be unlocking early.
    func setUsualApps(_ apps: Set<String>) {
        guard !usualInUse else { return }
        usualApps = apps
        MacLockApps.usual = apps
    }

    /// A lock's own apps, or nil for the usual ones. Not for a lock that's on.
    func setApps(_ apps: Set<String>?, for lock: ScreenLock) {
        guard LockClock.until(lock) == nil else { return }
        lockApps[lock.id] = apps == usualApps ? nil : apps
        MacLockApps.perLock = lockApps
    }

    /// The server's locks, then what holds now.
    func sync() async {
        do {
            let list = try await api.locks()
            locks = list.locks + testLocks
            passes = list.passes
            lastError = nil
            limits = list.limits ?? []
            let today = MacUsage.key(Date())
            for limit in limits where limit.openToday { limitOpened[limit.id] = today }
            let knownLimits = Set(limits.map(\.id))
            if limitApps.keys.contains(where: { !knownLimits.contains($0) }) {
                limitApps = limitApps.filter { knownLimits.contains($0.key) }
                MacLockApps.perLimit = limitApps
            }
            checkLimits()
            // A lock gone from the server takes its apps with it.
            let known = Set(list.locks.map(\.id))
            if lockApps.keys.contains(where: { !known.contains($0) }) {
                lockApps = lockApps.filter { known.contains($0.key) }
                MacLockApps.perLock = lockApps
            }
        } catch APIError.server(404, _) {
            return // an older server, without locks
        } catch {
            lastError = error.localizedDescription
        }
        tick()
    }

    /// What holds now, and a wake-up at the next start or end. The minute's fetch catches anything the server
    /// changed in between.
    private func tick() {
        let now = Date()
        let on = LockClock.current(locks, at: now)
        if on?.lock != current?.lock || on?.until != current?.until { current = on }
        let strict = LockClock.current(locks.filter(\.isStrict), at: now)
        if strict?.lock != strictOn?.lock || strict?.until != strictOn?.until { strictOn = strict }

        nextTick?.cancel()
        guard let next = LockClock.nextChange(locks, after: now) else { return }
        // A second past the change, so the lock's start (inclusive) or end (exclusive) has happened.
        let wait = next.timeIntervalSince(now) + 1
        nextTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), clock: .continuous) // keeps counting while the Mac sleeps
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Debug builds only: `-shieldTest 2` on launch (`-shieldStrict YES` for a strict one) adds a local 2-minute
    /// one-off over the usual apps (or `-shieldApps com.apple.iCal,com.apple.mail`), never sent to the server, to try
    /// the shield without locking the phone.
    private var testLocks: [ScreenLock] = {
        #if DEBUG
        let minutes = UserDefaults.standard.integer(forKey: "shieldTest")
        guard minutes > 0 else { return [] }
        let strict = UserDefaults.standard.bool(forKey: "shieldStrict")
        let now = Date(), end = now.addingTimeInterval(Double(minutes) * 60)
        let iso = ISO8601DateFormatter()
        return [ScreenLock(id: -1, title: "Shield test", once: true, start: nil, end: nil, days: nil,
                           startsAt: iso.string(from: now), endsAt: iso.string(from: end), enabled: true,
                           strict: strict, agent: nil, locked: true, until: iso.string(from: end), openUntil: nil,
                           next: nil, summary: "Test")]
        #else
        return []
        #endif
    }()

    // MARK: Changes from the app (the same endpoints as the phone, so Coach sees the Mac's unlocks too)

    func lockNow(minutes: Int, strict: Bool = false) async {
        await change {
            _ = try await self.api.createLock(NewLock(title: strict ? "Strict focus" : "Focus", minutes: minutes,
                                                      strict: strict ? true : nil))
        }
    }

    /// A weekly lock, new or changed, with the Mac apps it covers (nil: the usual ones). One that's on now only takes
    /// a new name, or strict (never back to not strict).
    func save(_ lock: ScreenLock?, title: String, start: String, end: String, days: [Int], enabled: Bool,
              strict: Bool, apps: Set<String>?) async -> Bool {
        await change {
            if let lock {
                let on = lock.locked
                _ = try await self.api.updateLock(lock.id, LockPatch(title: title, start: on ? nil : start,
                                                                     end: on ? nil : end, days: on ? nil : days,
                                                                     enabled: on ? nil : enabled,
                                                                     strict: on && !strict ? nil : strict))
                if !on { self.setApps(apps, for: lock) }
            } else {
                let made = try await self.api.createLock(NewLock(title: title, start: start, end: end, days: days,
                                                                 strict: strict ? true : nil))
                self.lockApps[made.id] = apps == self.usualApps ? nil : apps
                MacLockApps.perLock = self.lockApps
            }
        }
    }

    /// A lock that uses the usual apps is on: they can't change until it's over.
    var usualInUse: Bool { locks.contains { lockApps[$0.id] == nil && LockClock.until($0) != nil } }

    func setEnabled(_ lock: ScreenLock, _ on: Bool) async {
        await change { _ = try await self.api.updateLock(lock.id, LockPatch(enabled: on)) }
    }

    func unlock(_ lock: ScreenLock, reason: String, pass: Bool = false) async -> Bool {
        if lock.id < 0 {
            testLocks.removeAll { $0.id == lock.id }
            locks.removeAll { $0.id == lock.id }
            tick()
            return true
        }
        return await change { _ = try await self.api.unlock(lock.id, reason: reason, pass: pass) }
    }

    func delete(_ lock: ScreenLock) async -> Bool {
        await change { try await self.api.deleteLock(lock.id) }
    }

    // MARK: Daily limits on this Mac

    /// The time this Mac spent today in a limit's apps.
    func usedToday(_ limit: ScreenLimit) -> TimeInterval {
        MacUsage.shared.limitSeconds(limit.id, apps: limitApps[limit.id] ?? [])
    }

    /// Reached here today (when), or nil.
    func reachedHere(_ limit: ScreenLimit) -> Date? {
        guard let hit = limitHits[limit.id], hit.date == MacUsage.key(Date()) else { return nil }
        return hit.at
    }

    func holds(_ limit: ScreenLimit) -> Bool { heldLimits.contains(limit.id) }

    /// A limit whose apps have had their minutes today is reached: told to the server (so the phone and Coach see
    /// it) and held until midnight, unless it's been ended early for today.
    private func checkLimits() {
        let now = Date()
        let today = MacUsage.key(now)
        var reached: [UsageUpload.Hit] = []
        for limit in limits where limit.enabled && limit.counts(on: now) && limitHits[limit.id]?.date != today {
            guard let apps = limitApps[limit.id], !apps.isEmpty,
                  MacUsage.shared.limitSeconds(limit.id, apps: apps, on: now) >= Double(limit.minutes) * 60 else { continue }
            limitHits[limit.id] = MacLimitHit(date: today, at: now)
            reached.append(.init(id: limit.id, date: today, at: now.formatted(.iso8601)))
        }
        if !reached.isEmpty {
            limitHits = limitHits.filter { $0.value.date >= MacUsage.key(now.addingTimeInterval(-7 * 86400)) }
            MacLockApps.limitHits = limitHits
            Task { try? await api.uploadUsage(UsageUpload(days: [], limits: reached)) }
        }
        let held = Set(limits.filter { limit in
            limit.enabled && limit.counts(on: now) && limitHits[limit.id]?.date == today && limitOpened[limit.id] != today
        }.map(\.id))
        if held != heldLimits { heldLimits = held }
    }

    /// A limit's Mac apps. Not while it holds: that would be ending it early.
    func setApps(_ apps: Set<String>, for limit: ScreenLimit) {
        guard !holds(limit) else { return }
        limitApps[limit.id] = apps.isEmpty ? nil : apps
        MacLockApps.perLimit = limitApps
        checkLimits()
    }

    /// A limit, new or changed, with its Mac apps.
    func saveLimit(_ limit: ScreenLimit?, title: String, minutes: Int, days: [Int], enabled: Bool, strict: Bool,
                   apps: Set<String>) async -> Bool {
        await change {
            if let limit {
                _ = try await self.api.updateLimit(limit.id, LimitPatch(title: title, minutes: minutes, days: days,
                                                                        enabled: enabled, strict: strict))
                self.setApps(apps, for: limit)
            } else {
                let made = try await self.api.createLimit(NewLimit(title: title, minutes: minutes, days: days, strict: strict))
                self.limitApps[made.id] = apps.isEmpty ? nil : apps
                MacLockApps.perLimit = self.limitApps
            }
        }
    }

    func setEnabled(_ limit: ScreenLimit, _ on: Bool) async {
        await change { _ = try await self.api.updateLimit(limit.id, LimitPatch(enabled: on)) }
    }

    func delete(_ limit: ScreenLimit) async -> Bool {
        await change { try await self.api.deleteLimit(limit.id) }
    }

    /// Ends a lock early, or a limit reached today until midnight (on the phone too).
    func unlock(_ hold: MacHold, reason: String, pass: Bool = false) async -> Bool {
        if let lock = hold.lock { return await unlock(lock, reason: reason, pass: pass) }
        guard let limit = hold.limit else { return false }
        // Reached here but the server hasn't heard yet: tell it first, or it refuses to end what isn't reached.
        if !limit.reachedToday, let at = reachedHere(limit) {
            try? await api.uploadUsage(UsageUpload(days: [], limits: [.init(id: limit.id, date: MacUsage.key(at),
                                                                              at: at.formatted(.iso8601))]))
        }
        let ok = await change { _ = try await self.api.unlockLimit(limit.id, reason: reason, pass: pass) }
        if ok {
            limitOpened[limit.id] = MacUsage.key(Date())
            checkLimits()
        }
        return ok
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

/// What a lock or a limit holding now is, for the shield and the unlock sheet.
struct MacHold: Equatable {
    var lock: ScreenLock?
    var limit: ScreenLimit?
    let until: Date

    init(lock: ScreenLock, until: Date) { self.lock = lock; self.until = until }
    init(limit: ScreenLimit, until: Date) { self.limit = limit; self.until = until }

    var title: String { lock?.title ?? limit?.title ?? "" }
    var isStrict: Bool { lock?.isStrict ?? limit?.strict ?? false }
    var agent: String? { lock?.agent }
    /// What ending it early does.
    var afterUnlock: String {
        if limit != nil { return "Open until midnight; it counts again tomorrow." }
        return lock?.once == true ? "Ends the lock for good." : "It's back next time."
    }
}

/// A limit reached on this Mac: the local day, and when.
struct MacLimitHit: Codable {
    let date: String
    let at: Date
}

/// What the Mac's locks cover, kept in this Mac's defaults: the phone's picks are tokens that mean nothing here.
enum MacLockApps {
    /// Never covered: Aide (the shield and unlocking live here), Finder and System Settings.
    static let never: Set<String> = Set([Bundle.main.bundleIdentifier, "com.apple.finder", "com.apple.systempreferences",
                                         "com.apple.loginwindow"].compactMap { $0 })

    /// Until the app picker (#30, step 2), Safari.
    static var usual: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "macLockUsual") ?? ["com.apple.Safari"]) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "macLockUsual") }
    }

    static var perLimit: [Int: Set<String>] {
        get { ids(UserDefaults.standard.dictionary(forKey: "macLimitApps")) }
        set { UserDefaults.standard.set(strings(newValue), forKey: "macLimitApps") }
    }

    static var limitHits: [Int: MacLimitHit] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "macLimitHits"),
                  let hits = try? JSONDecoder().decode([String: MacLimitHit].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: hits.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        set {
            let hits = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(hits), forKey: "macLimitHits")
        }
    }

    private static func ids(_ stored: [String: Any]?) -> [Int: Set<String>] {
        let stored = stored as? [String: [String]] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, Set(value)) } })
    }

    private static func strings(_ value: [Int: Set<String>]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: value.map { (String($0.key), $0.value.sorted()) })
    }

    static var perLock: [Int: Set<String>] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: "macLockApps") as? [String: [String]] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, Set(value)) } })
        }
        set {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value.sorted()) }),
                                      forKey: "macLockApps")
        }
    }
}
