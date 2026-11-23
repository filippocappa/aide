import AppKit
import Foundation

/// Screen Time locks on the Mac (docs/API.md, "Screen Time"; issue #30). Apple's Screen Time API is iOS-only, so
/// Aide enforces the locks itself: the same locks as the phone, read from the server and worked out here
/// (`LockClock`), so a lock starts and ends on time without asking the server again. The Mac gets no silent pushes,
/// so it fetches on open and after a chat turn (`AppEnvironment`, as the phone does), every minute while running, and
/// when the Mac wakes. What a lock covers is the Mac's own (apps by bundle ID, kept on this Mac, never on the server);
/// `MacShield` covers them while a lock holds. App lists ("App lists") carry their Mac apps on the server, so a lock,
/// limit or ration with a list covers the list's; a ration ("Rations") keeps its apps closed but for the day's opens,
/// shared with the phone; the Focus filter (`AideFocusFilter`) closes a list's apps while a Focus is on.
/// The app and Aide Guard (`MacGuard`) each have one: the Guard's enforces (`enforces`), the app's is for its pages
/// and enforces only while the Guard isn't running. Each tells the other after a change.
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
    /// What stays open in a focus session's rounds, by bundle ID; a round closes every other app (not websites).
    @Published private(set) var focusApps: Set<String> = MacLockApps.focus
    /// Daily app limits (docs/API.md, "Daily app limits"), the same as the phone's. Each device counts its own time:
    /// here, the time this Mac spent in the limit's Mac apps (`MacUsage`).
    @Published private(set) var limits: [ScreenLimit] = []
    /// The Mac apps each limit picked for itself, by limit id. None: the limit does nothing on this Mac.
    @Published private(set) var limitApps: [Int: Set<String>] = MacLockApps.perLimit {
        didSet { MacUsage.shared.limitApps = countedApps }
    }
    /// App lists (their Mac apps live on the server) and rations.
    @Published private(set) var lists: [ScreenList] = MacLockApps.lists {
        didSet { MacUsage.shared.limitApps = countedApps }
    }
    @Published private(set) var rations: [ScreenRation] = []
    /// Each ration's open going on now: it ends at this time unless its apps are used again before.
    @Published private(set) var rationOpenUntil: [Int: Date] = [:]
    /// The list the Focus filter locks while a Focus is on.
    @Published private(set) var focusFilterList: Int? = MacLockApps.focusFilterList
    /// Opens spent here that the server hasn't had yet (offline): sent at the next sync.
    private var unsentOpens: [(ration: Int, body: RationOpenBody)] = []
    /// The limits holding now on this Mac: reached here today, not ended early.
    @Published private(set) var heldLimits: Set<Int> = []
    private var limitHits: [Int: MacLimitHit] = MacLockApps.limitHits
    private var limitOpened: [Int: String] = [:]
    /// This process keeps the limits: it notices when one is reached and tells the server. Off in the app while the
    /// Guard runs: then the app reads the Guard's hits.
    var enforces = true {
        didSet { if enforces != oldValue { checkLimits() } }
    }

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
        MacUsage.shared.limitApps = countedApps
        #if !AIDE_GUARD
        observers.append(NotificationCenter.default.addObserver(forName: FocusFilterState.changed, object: nil,
                                                                queue: .main) { _ in
            Task { @MainActor [weak self] in
                self?.focusFilterList = MacLockApps.focusFilterList
                MacGuard.tell()
            }
        })
        #endif
        // The other side changed something: the picks again, then the server's locks.
        observers.append(MacGuard.listen { [weak self] in
            self?.reloadPicks()
            await self?.sync()
        })
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

    /// What this Mac picked, read again (the other side may have changed it).
    func reloadPicks() {
        usualApps = MacLockApps.usual
        lockApps = MacLockApps.perLock
        focusApps = MacLockApps.focus
        limitApps = MacLockApps.perLimit
        focusFilterList = MacLockApps.focusFilterList
        if !enforces { limitHits = MacLockApps.limitHits }
    }

    /// Nothing to allow on the Mac: Aide enforces the locks itself.
    var isAuthorized: Bool { true }

    func apps(for lock: ScreenLock) -> Set<String> {
        #if DEBUG
        if lock.id < 0, let test = UserDefaults.standard.string(forKey: "shieldApps") {
            return Set(test.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        #endif
        // A list locks only its Mac apps: nothing while it has none.
        if let mac = listApps(lock.list) { return mac }
        return lockApps[lock.id] ?? usualApps
    }

    func list(_ id: Int?) -> ScreenList? { id.flatMap { id in lists.first { $0.id == id } } }

    /// A list's Mac apps, nil for no list.
    func listApps(_ id: Int?) -> Set<String>? { list(id).map { Set($0.mac) } }

    /// What a limit counts here: its list's apps, else its own.
    func apps(for limit: ScreenLimit) -> Set<String> { listApps(limit.list) ?? limitApps[limit.id] ?? [] }

    func apps(for ration: ScreenRation) -> Set<String> { listApps(ration.list) ?? [] }

    /// Every limit's apps, for `MacUsage` to count.
    private var countedApps: [Int: Set<String>] {
        Dictionary(uniqueKeysWithValues: limits.map { ($0.id, apps(for: $0)) }.filter { !$0.1.isEmpty })
    }

    /// The lock or limit that covers an app now (the one that ends last), or nil: the app is free.
    func covering(_ bundleID: String?) -> MacHold? {
        guard let bundleID, !MacLockApps.never.contains(bundleID) else { return nil }
        let now = Date()
        let byLocks = locks.filter { $0.focus != nil ? focusCovers(bundleID) : MacSites.covers(apps(for: $0), bundleID) }
            .compactMap { lock in LockClock.until(lock, at: now).map { MacHold(lock: lock, until: $0) } }
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 + 3600)
        let byLimits = limits.filter { heldLimits.contains($0.id) && MacSites.covers(apps(for: $0), bundleID) }
            .map { MacHold(limit: $0, until: Calendar.current.startOfDay(for: midnight)) }
        if let strongest = (byLocks + byLimits).max(by: { $0.until < $1.until }) { return strongest }
        if let list = list(focusFilterList), MacSites.covers(Set(list.mac), bundleID) {
            return MacHold(list: list, until: .distantFuture)
        }
        return rations.first { rationHolds($0, now) && MacSites.covers(apps(for: $0), bundleID) }
            .map { MacHold(ration: $0, until: Calendar.current.startOfDay(for: midnight)) }
    }

    // MARK: Rations (docs/API.md, "Rations")

    func rationHolds(_ ration: ScreenRation, _ now: Date = Date()) -> Bool {
        ration.enabled && (rationOpenUntil[ration.id] ?? .distantPast) <= now
    }

    func rationOpenNow(_ ration: ScreenRation) -> Bool { (rationOpenUntil[ration.id] ?? .distantPast) > Date() }

    /// Today's opens left: the server's count at the last sync, less the ones spent here it hasn't had.
    func opensLeft(_ ration: ScreenRation) -> Int {
        max(ration.leftToday - unsentOpens.filter { $0.ration == ration.id }.count, 0)
    }

    /// Spends one of today's opens here (the nudge's Open): told to the server first, so the phone's count agrees;
    /// offline, from what the Mac last knew. False when none are left.
    func openRation(_ ration: ScreenRation) async -> Bool {
        let body = RationOpenBody(key: UUID().uuidString, device: "mac", at: Date().formatted(.iso8601))
        do {
            let got = try await api.openRation(ration.id, body)
            rations = rations.map { $0.id == got.id ? got : $0 }
            lastError = nil
        } catch APIError.server(let code, let message) where code == 400 || code == 404 {
            lastError = message
            await sync()
            return false
        } catch {
            guard opensLeft(ration) > 0 else { return false }
            var granted = body
            granted.granted = true
            unsentOpens.append((ration.id, granted))
        }
        rationOpenUntil[ration.id] = Date().addingTimeInterval(Double(ration.gap) * 60)
        return true
    }

    /// One of a ration's apps or sites is in use now: its open goes on `gap` minutes more.
    func rationInUse(_ bundleID: String) {
        let now = Date()
        for ration in rations where (rationOpenUntil[ration.id] ?? .distantPast) > now
            && MacSites.covers(apps(for: ration), bundleID) {
            rationOpenUntil[ration.id] = now.addingTimeInterval(Double(ration.gap) * 60)
        }
    }

    /// Opens over (unused for `gap` minutes) close their apps again.
    private func endRationOpens() {
        let now = Date()
        // The app in front counts as use.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { rationInUse(front) }
        let over = rationOpenUntil.filter { $0.value <= now }
        guard !over.isEmpty else { return }
        for id in over.keys { rationOpenUntil[id] = nil }
    }

    private func sendOpens() async {
        for open in unsentOpens {
            do {
                try await api.openRation(open.ration, open.body)
            } catch APIError.server(400, _), APIError.server(404, _) {
                // Gone or off: nothing to count.
            } catch {
                continue
            }
            unsentOpens.removeAll { $0.body.key == open.body.key }
        }
    }

    // MARK: App lists

    /// A list's name or Mac apps on the server (the phone sees the name; its own apps stay its own). Taking Mac apps
    /// out while a lock or limit using it holds is refused there.
    func saveList(_ list: ScreenList?, name: String, mac: Set<String>) async -> Bool {
        await change {
            if let list {
                _ = try await self.api.updateList(list.id, ScreenListBody(name: name == list.name ? nil : name,
                                                                          mac: mac.sorted()))
            } else {
                _ = try await self.api.createList(ScreenListBody(name: name, mac: mac.sorted()))
            }
        }
    }

    func delete(_ list: ScreenList) async -> Bool {
        await change { try await self.api.deleteList(list.id) }
    }

    func listInUse(_ id: Int) -> Bool {
        locks.contains { $0.list == id && LockClock.until($0) != nil } || limits.contains { $0.list == id && holds($0) }
    }

    /// A strict lock or limit using the list holds now: its apps can be added, not taken out.
    func listHeldStrictly(_ id: Int) -> Bool {
        locks.contains { $0.list == id && $0.isStrict && LockClock.until($0) != nil }
            || limits.contains { $0.list == id && $0.strict && holds($0) }
    }

    func saveRation(_ ration: ScreenRation?, title: String, opens: Int, gap: Int, list: Int?) async -> Bool {
        await change {
            if let ration {
                _ = try await self.api.updateRation(ration.id, RationBody(title: title, opens: opens, gap: gap,
                                                                          list: list == ration.list ? nil : (list ?? 0)))
            } else {
                _ = try await self.api.createRation(RationBody(title: title, opens: opens, gap: gap, list: list))
            }
        }
    }

    func setEnabled(_ ration: ScreenRation, _ on: Bool) async {
        await change { _ = try await self.api.updateRation(ration.id, RationBody(enabled: on)) }
    }

    func delete(_ ration: ScreenRation) async -> Bool {
        await change { try await self.api.deleteRation(ration.id) }
    }

    /// A focus round covers every app you'd switch to (a regular app, or one not running) but the focus ones; never
    /// a website (the browser itself is an app) or a background helper.
    private func focusCovers(_ bundleID: String) -> Bool {
        guard MacSites.site(of: bundleID) == nil, !focusApps.contains(bundleID) else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return running.isEmpty || running.contains { $0.activationPolicy == .regular }
    }

    /// The focus apps. Not during a round: that would be unlocking early.
    func setFocusApps(_ apps: Set<String>) {
        guard !focusInUse else { return }
        focusApps = apps
        MacLockApps.focus = apps
        MacGuard.tell()
    }

    var focusInUse: Bool { locks.contains { $0.focus != nil && LockClock.until($0) != nil } }

    /// The usual apps. Not while a lock that uses them is on: that would be unlocking early.
    func setUsualApps(_ apps: Set<String>) {
        guard !usualInUse else { return }
        usualApps = apps
        MacLockApps.usual = apps
        MacGuard.tell()
    }

    /// A lock's own apps, or nil for the usual ones. Not for a lock that's on.
    func setApps(_ apps: Set<String>?, for lock: ScreenLock) {
        guard LockClock.until(lock) == nil else { return }
        lockApps[lock.id] = apps == usualApps ? nil : apps
        MacLockApps.perLock = lockApps
        MacGuard.tell()
    }

    /// The server's locks, then what holds now.
    func sync() async {
        await sendOpens()
        do {
            let list = try await api.locks()
            locks = list.locks + testLocks
            passes = list.passes
            lastError = nil
            limits = list.limits ?? []
            if let got = list.lists {
                lists = got
                MacLockApps.lists = got
            }
            rations = list.rations ?? []
            rationOpenUntil = rationOpenUntil.filter { id, _ in rations.contains { $0.id == id && $0.enabled } }
            MacUsage.shared.limitApps = countedApps
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
    /// one-off over the usual apps (or `-shieldApps com.apple.iCal,com.apple.mail`, or a list's: `-shieldList 2`),
    /// never sent to the server, to try the shield without locking the phone.
    private var testLocks: [ScreenLock] = {
        #if DEBUG
        let minutes = UserDefaults.standard.integer(forKey: "shieldTest")
        guard minutes > 0 else { return [] }
        let strict = UserDefaults.standard.bool(forKey: "shieldStrict")
        let list = UserDefaults.standard.integer(forKey: "shieldList")
        let now = Date(), end = now.addingTimeInterval(Double(minutes) * 60)
        let iso = ISO8601DateFormatter()
        return [ScreenLock(id: -1, title: "Shield test", once: true, start: nil, end: nil, days: nil,
                           startsAt: iso.string(from: now), endsAt: iso.string(from: end), enabled: true,
                           strict: strict, agent: nil, locked: true, until: iso.string(from: end), openUntil: nil,
                           next: nil, summary: "Test", list: list > 0 ? list : nil)]
        #else
        return []
        #endif
    }()

    // MARK: Changes from the app (the same endpoints as the phone, so Coach sees the Mac's unlocks too)

    func lockNow(minutes: Int, strict: Bool = false, list: Int? = nil) async {
        await change {
            _ = try await self.api.createLock(NewLock(title: strict ? "Strict focus" : self.list(list)?.name ?? "Focus",
                                                      minutes: minutes, strict: strict ? true : nil, list: list))
        }
    }

    /// A weekly lock, new or changed, with the Mac apps it covers (a list's, its own, or nil: the usual ones). One
    /// that's on now only takes a new name, or strict (never back to not strict).
    func save(_ lock: ScreenLock?, title: String, start: String, end: String, days: [Int], enabled: Bool,
              strict: Bool, list: Int? = nil, apps: Set<String>?) async -> Bool {
        await change {
            if let lock {
                let on = lock.locked
                _ = try await self.api.updateLock(lock.id, LockPatch(title: title, start: on ? nil : start,
                                                                     end: on ? nil : end, days: on ? nil : days,
                                                                     enabled: on ? nil : enabled,
                                                                     strict: on && !strict ? nil : strict,
                                                                     list: on || list == lock.list ? nil : (list ?? 0)))
                if !on { self.setApps(apps, for: lock) }
            } else {
                let made = try await self.api.createLock(NewLock(title: title, start: start, end: end, days: days,
                                                                 strict: strict ? true : nil, list: list))
                self.lockApps[made.id] = apps == self.usualApps ? nil : apps
                MacLockApps.perLock = self.lockApps
            }
        }
    }

    /// A lock that uses the usual apps is on: they can't change until it's over.
    var usualInUse: Bool {
        locks.contains { lock in
            lock.focus == nil && lockApps[lock.id] == nil && lock.list == nil && LockClock.until(lock) != nil
        }
    }

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
        MacUsage.shared.limitSeconds(limit.id, apps: apps(for: limit))
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
        endRationOpens()
        let now = Date()
        let today = MacUsage.key(now)
        var reached: [UsageUpload.Hit] = []
        if !enforces { limitHits = MacLockApps.limitHits }
        for limit in limits where enforces && limit.enabled && limit.counts(on: now) && limitHits[limit.id]?.date != today {
            let apps = apps(for: limit)
            guard !apps.isEmpty,
                  MacUsage.shared.limitSeconds(limit.id, apps: apps, on: now) >= Double(limit.minutes) * 60 else { continue }
            limitHits[limit.id] = MacLimitHit(date: today, at: now)
            reached.append(.init(id: limit.id, date: today, at: now.formatted(.iso8601)))
        }
        if !reached.isEmpty {
            limitHits = limitHits.filter { $0.value.date >= MacUsage.key(now.addingTimeInterval(-7 * 86400)) }
            MacLockApps.limitHits = limitHits
            MacGuard.tell()
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
        MacGuard.tell()
    }

    /// A limit, new or changed, with its Mac apps.
    func saveLimit(_ limit: ScreenLimit?, title: String, minutes: Int, days: [Int], enabled: Bool, strict: Bool,
                   list: Int? = nil, apps: Set<String>) async -> Bool {
        await change {
            if let limit {
                _ = try await self.api.updateLimit(limit.id, LimitPatch(title: title, minutes: minutes, days: days,
                                                                        enabled: enabled, strict: strict,
                                                                        list: list == limit.list ? nil : (list ?? 0)))
                self.setApps(apps, for: limit)
            } else {
                let made = try await self.api.createLimit(NewLimit(title: title, minutes: minutes, days: days,
                                                                   strict: strict, list: list))
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
        MacGuard.tell()
        return true
    }
}

/// What a lock, a limit, the Focus filter or a ration holding now is, for the shield and the unlock sheet.
struct MacHold: Equatable {
    var lock: ScreenLock?
    var limit: ScreenLimit?
    /// The Focus filter's list: it holds while the Focus is on.
    var list: ScreenList?
    /// A ration: its nudge spends an open instead of asking why.
    var ration: ScreenRation?
    let until: Date

    init(lock: ScreenLock, until: Date) { self.lock = lock; self.until = until }
    init(limit: ScreenLimit, until: Date) { self.limit = limit; self.until = until }
    init(list: ScreenList, until: Date) { self.list = list; self.until = until }
    init(ration: ScreenRation, until: Date) { self.ration = ration; self.until = until }

    var title: String { lock?.title ?? limit?.title ?? list?.name ?? ration?.title ?? "" }
    var isStrict: Bool { lock?.isStrict ?? limit?.strict ?? false }
    var agent: String? { lock?.agent }
    /// A time as the shield and the glance say it: 07:00 today, else with the day.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

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

/// What the Mac's locks cover, kept in the app's defaults (the Guard reads them, `MacGuard.defaults`): the phone's
/// picks are tokens that mean nothing here.
enum MacLockApps {
    /// Never covered: Aide and its Guard (the shield and unlocking live there), Finder and System Settings.
    static let never: Set<String> = [MacGuard.appID, MacGuard.guardID, "com.apple.finder", "com.apple.systempreferences",
                                     "com.apple.loginwindow"]

    /// Until the app picker (#30, step 2), Safari.
    static var usual: Set<String> {
        get { Set(MacGuard.defaults.stringArray(forKey: "macLockUsual") ?? ["com.apple.Safari"]) }
        set { MacGuard.defaults.set(newValue.sorted(), forKey: "macLockUsual") }
    }

    /// Open in a focus round: notes, the PDFs, a calculator, a dictionary (Aide itself always is).
    static var focus: Set<String> {
        get {
            Set(MacGuard.defaults.stringArray(forKey: "macFocusApps")
                ?? ["com.apple.Notes", "com.apple.Preview", "md.obsidian", "com.apple.TextEdit", "com.apple.calculator",
                    "com.apple.Dictionary"])
        }
        set { MacGuard.defaults.set(newValue.sorted(), forKey: "macFocusApps") }
    }

    /// The app lists as last synced, for the Focus filter's choices.
    static var lists: [ScreenList] {
        get { MacGuard.defaults.data(forKey: "macScreenLists").flatMap { try? JSONDecoder().decode([ScreenList].self, from: $0) } ?? [] }
        set { MacGuard.defaults.set(try? JSONEncoder().encode(newValue), forKey: "macScreenLists") }
    }

    static var focusFilterList: Int? {
        get { MacGuard.defaults.object(forKey: "macFocusFilterList") as? Int }
        set { MacGuard.defaults.set(newValue, forKey: "macFocusFilterList") }
    }

    static var perLimit: [Int: Set<String>] {
        get { ids(MacGuard.defaults.dictionary(forKey: "macLimitApps")) }
        set { MacGuard.defaults.set(strings(newValue), forKey: "macLimitApps") }
    }

    static var limitHits: [Int: MacLimitHit] {
        get {
            guard let data = MacGuard.defaults.data(forKey: "macLimitHits"),
                  let hits = try? JSONDecoder().decode([String: MacLimitHit].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: hits.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        set {
            let hits = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            MacGuard.defaults.set(try? JSONEncoder().encode(hits), forKey: "macLimitHits")
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
            let stored = MacGuard.defaults.dictionary(forKey: "macLockApps") as? [String: [String]] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, Set(value)) } })
        }
        set {
            MacGuard.defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value.sorted()) }),
                                      forKey: "macLockApps")
        }
    }
}
