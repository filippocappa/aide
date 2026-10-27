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
        locks.compactMap { lock in LockBook.until(lock).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// A lock on now uses the usual apps: they can't change until it's over (that would be unlocking early).
    var usualInUse: Bool { locks.contains { apps[$0.id] == nil && LockBook.until($0) != nil } }

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

    /// The server's locks, set on the phone.
    func sync() async {
        authorization = AuthorizationCenter.shared.authorizationStatus
        do {
            let list = try await api.locks()
            locks = list.locks
            LockBook.locks = list.locks
            lastError = nil
            if list.device.authorized != isAuthorized || list.device.allowedApps != allowedCount { await report() }
        } catch APIError.server(404, _) {
            return // an older server, without locks
        } catch {
            lastError = error.localizedDescription
        }
        apply()
    }

    /// Each lock's schedule watched (restarted only when it changed), the ones gone stopped, and the shields set
    /// for what holds right now.
    private func apply() {
        guard isAuthorized else { return }
        var scheduled = LockBook.scheduled
        var wanted = Set<DeviceActivityName>()
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
        for name in center.activities where LockBook.id(of: name) != nil && !wanted.contains(name) {
            center.stopMonitoring([name])
        }
        // A lock that's gone from the server (deleted, ended early, over) opens if it had shielded anything.
        let known = Set(locks.map(\.id))
        for key in Array(scheduled.keys) where !wanted.contains(DeviceActivityName(key)) {
            scheduled[key] = nil
            if let id = LockBook.id(of: DeviceActivityName(key)), !known.contains(id) { LockBook.open(id) }
        }
        LockBook.scheduled = scheduled
        if apps.keys.contains(where: { !known.contains($0) }) {
            apps = apps.filter { known.contains($0.key) }
            LockBook.apps = apps
        }
        for lock in locks {
            if LockBook.until(lock) != nil { LockBook.shield(lock.id) } else { LockBook.open(lock.id) }
        }
    }

    /// So the agents can say when a lock won't hold.
    func report() async {
        try? await api.reportScreenTime(ScreenTimeDevice(authorized: isAuthorized, allowedApps: allowedCount))
    }

    // MARK: Changes from the app

    func lockNow(minutes: Int, title: String = "Focus") async {
        await change { _ = try await self.api.createLock(NewLock(title: title, minutes: minutes)) }
    }

    func save(_ lock: ScreenLock?, title: String, start: String, end: String, days: [Int], enabled: Bool,
              apps picked: LockApps) async -> Bool {
        await change {
            if let lock {
                _ = try await self.api.updateLock(lock.id, LockPatch(title: title, start: lock.locked ? nil : start,
                                                                     end: lock.locked ? nil : end,
                                                                     days: lock.locked ? nil : days,
                                                                     enabled: lock.locked ? nil : enabled))
                if !lock.locked { self.setApps(picked, for: lock.id) }
            } else {
                let made = try await self.api.createLock(NewLock(title: title, start: start, end: end, days: days))
                self.setApps(picked, for: made.id)
            }
        }
    }

    func setEnabled(_ lock: ScreenLock, _ on: Bool) async {
        await change { _ = try await self.api.updateLock(lock.id, LockPatch(enabled: on)) }
    }

    func unlock(_ lock: ScreenLock, reason: String) async -> Bool {
        let done = await change { _ = try await self.api.unlock(lock.id, reason: reason) }
        if done { LockBook.open(lock.id) } // sync already did, unless the server was slow to say so
        return done
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
