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

    private let api: APIClient
    private var poll: Task<Void, Never>?
    private var nextTick: Task<Void, Never>?
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

    /// The lock that covers an app now (the one that ends last), or nil: the app is free.
    func covering(_ bundleID: String?) -> (lock: ScreenLock, until: Date)? {
        guard let bundleID, !MacLockApps.never.contains(bundleID) else { return nil }
        let now = Date()
        return locks.filter { apps(for: $0).contains(bundleID) }
            .compactMap { lock in LockClock.until(lock, at: now).map { (lock, $0) } }
            .max { $0.1 < $1.1 }
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
