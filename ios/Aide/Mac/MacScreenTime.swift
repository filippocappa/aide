import AppKit
import Foundation

/// Screen Time locks on the Mac (docs/API.md, "Screen Time"; issue #30). Apple's Screen Time API is iOS-only, so
/// Aide enforces the locks itself: the same locks as the phone, read from the server and worked out here
/// (`LockClock`), so a lock starts and ends on time without asking the server again. The Mac gets no silent pushes,
/// so it fetches on open and after a chat turn (`AppEnvironment`, as the phone does), every minute while running, and
/// when the Mac wakes. What a lock covers on the Mac and the shield come later.
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published private(set) var locks: [ScreenLock] = []
    @Published private(set) var passes: EmergencyPasses?
    @Published private(set) var lastError: String?
    /// The lock on now that ends last, recomputed at every start and end.
    @Published private(set) var current: (lock: ScreenLock, until: Date)?
    /// A strict lock on now: only an emergency pass ends it early, and Quit is refused.
    @Published private(set) var strictOn: (lock: ScreenLock, until: Date)?

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
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.tick() }
            })
        }
    }

    /// Nothing to allow on the Mac: Aide enforces the locks itself.
    var isAuthorized: Bool { true }

    /// The server's locks, then what holds now.
    func sync() async {
        do {
            let list = try await api.locks()
            locks = list.locks
            passes = list.passes
            lastError = nil
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

    // MARK: Changes from the app (the same endpoints as the phone, so Coach sees the Mac's unlocks too)

    func lockNow(minutes: Int, strict: Bool = false) async {
        await change {
            _ = try await self.api.createLock(NewLock(title: strict ? "Strict focus" : "Focus", minutes: minutes,
                                                      strict: strict ? true : nil))
        }
    }

    func setEnabled(_ lock: ScreenLock, _ on: Bool) async {
        await change { _ = try await self.api.updateLock(lock.id, LockPatch(enabled: on)) }
    }

    func unlock(_ lock: ScreenLock, reason: String, pass: Bool = false) async -> Bool {
        await change { _ = try await self.api.unlock(lock.id, reason: reason, pass: pass) }
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
