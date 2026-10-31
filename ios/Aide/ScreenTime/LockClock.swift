import Foundation

/// When a lock holds, worked out on the device so it starts and ends on time without asking the server. Plain
/// Foundation, so the phone (and its extensions) and the Mac share it; the phone's DeviceActivity side is in LockBook.
enum LockClock {
    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    static func minutes(_ hhmm: String?) -> Int? {
        let parts = (hhmm ?? "").split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// When the lock opens, if it holds at `now`: on, in its time, and not unlocked early this time (a one-off
    /// unlocked early is gone from the server).
    static func until(_ lock: ScreenLock, at now: Date = Date()) -> Date? {
        if lock.once {
            guard let start = date(lock.startsAt), let end = date(lock.endsAt), start <= now, now < end else { return nil }
            return end
        }
        for (from, to) in times(of: lock, around: now, days: -1...0) where from <= now && now < to {
            if let opened = date(lock.openUntil), opened >= to { return nil }
            return to
        }
        return nil
    }

    /// The lock that holds at `now` and ends last: the one the shield names.
    static func current(_ locks: [ScreenLock], at now: Date = Date()) -> (lock: ScreenLock, until: Date)? {
        locks.compactMap { lock in until(lock, at: now).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// The next moment after `now` when any lock starts or ends, within a week: when to look again.
    static func nextChange(_ locks: [ScreenLock], after now: Date = Date()) -> Date? {
        var moments: [Date] = []
        for lock in locks {
            if lock.once {
                moments += [date(lock.startsAt), date(lock.endsAt)].compactMap { $0 }
            } else {
                for (from, to) in times(of: lock, around: now, days: -1...7) { moments += [from, to] }
            }
        }
        return moments.filter { $0 > now }.min()
    }

    /// A weekly schedule's times that start on the days `days` away from `now`'s (on its weekdays only). An `end`
    /// before the `start` is the next morning.
    private static func times(of lock: ScreenLock, around now: Date, days: ClosedRange<Int>) -> [(Date, Date)] {
        guard !lock.once, lock.enabled, let start = minutes(lock.start), let end = minutes(lock.end) else { return [] }
        let calendar = Calendar.current
        let length = ((end - start) % 1440 + 1440) % 1440
        let today = calendar.startOfDay(for: now)
        return days.compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let from = calendar.date(byAdding: .minute, value: start, to: day),
                  let to = calendar.date(byAdding: .minute, value: length, to: from) else { return nil }
            // Calendar's weekday is 1 = Sunday; the server's is ISO, 1 = Monday.
            let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
            guard lock.days?.isEmpty != false || lock.days!.contains(weekday) else { return nil }
            return (from, to)
        }
    }
}
