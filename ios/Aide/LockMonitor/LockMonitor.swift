import DeviceActivity
import Foundation

/// Turns each lock on and off on time with the app closed (docs/API.md, "Screen Time"). A schedule is watched
/// every day, so this checks the lock's days, and whether it was unlocked early, before shielding. Daily limits
/// ("Daily app limits") lock their apps when their threshold fires and open them when the next day starts; the
/// usage estimate ("Screen time estimates") keeps the day's highest step for the app to send.
final class LockMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if let id = LockBook.limitID(of: activity.rawValue) {
            LockBook.openLimit(id) // a new day
            return
        }
        guard let id = LockBook.id(of: activity), let lock = LockBook.locks.first(where: { $0.id == id }) else { return }
        // A moment ahead: the call can come a little before the minute it's for.
        if LockClock.until(lock, at: Date().addingTimeInterval(60)) != nil { LockBook.shield(id) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if let id = LockBook.limitID(of: activity.rawValue) {
            LockBook.openLimit(id)
        } else if let id = LockBook.id(of: activity) {
            LockBook.open(id)
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let now = Date()
        let today = LockBook.day(now)
        if let minutes = LockBook.usageMinutes(of: event) {
            var usage = LockBook.usage
            usage[today] = max(usage[today] ?? 0, minutes)
            // A few weeks is plenty: the app sends the last 7 days.
            for key in usage.keys where key < LockBook.day(now.addingTimeInterval(-30 * 86400)) { usage[key] = nil }
            LockBook.usage = usage
            return
        }
        guard let id = LockBook.limitID(of: event.rawValue),
              let limit = LockBook.limits.first(where: { $0.id == id }),
              limit.counts(on: now), LockBook.limitOpened[id] != today else { return }
        var hits = LockBook.limitHits
        if hits[id]?.date != today {
            hits[id] = LockBook.Hit(date: today, at: ISO8601DateFormatter().string(from: now))
            LockBook.limitHits = hits
        }
        LockBook.shieldLimit(id)
    }
}
