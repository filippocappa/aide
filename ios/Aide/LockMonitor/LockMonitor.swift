import DeviceActivity
import Foundation

/// Turns each lock on and off on time with the app closed (docs/API.md, "Screen Time"). A schedule is watched
/// every day, so this checks the lock's days, and whether it was unlocked early, before shielding.
final class LockMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard let id = LockBook.id(of: activity), let lock = LockBook.locks.first(where: { $0.id == id }) else { return }
        // A moment ahead: the call can come a little before the minute it's for.
        if LockBook.until(lock, at: Date().addingTimeInterval(60)) != nil { LockBook.shield(id) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if let id = LockBook.id(of: activity) { LockBook.open(id) }
    }
}
