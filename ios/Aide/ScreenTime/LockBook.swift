import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// The locks and what they let through, kept in the App Group so the monitor and shield extensions read them with
/// the app closed. The app writes; the extensions only read. Each lock shields through its own named store, so
/// two locks that overlap don't undo each other when one ends.
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

    /// What each lock was last scheduled with, so a sync only restarts the ones that changed.
    static var scheduled: [String: String] {
        get { defaults?.dictionary(forKey: "screenScheduled") as? [String: String] ?? [:] }
        set { defaults?.set(newValue, forKey: "screenScheduled") }
    }

    static func activity(_ id: Int) -> DeviceActivityName { DeviceActivityName("lock-\(id)") }

    static func id(of activity: DeviceActivityName) -> Int? {
        activity.rawValue.hasPrefix("lock-") ? Int(activity.rawValue.dropFirst(5)) : nil
    }

    private static func store(_ id: Int) -> ManagedSettingsStore { ManagedSettingsStore(named: .init("lock-\(id)")) }

    /// Shield everything but the allowed apps and sites.
    static func shield(_ id: Int) {
        let allowed = allowed
        let store = store(id)
        store.shield.applicationCategories = .all(except: allowed.applicationTokens)
        store.shield.webDomainCategories = .all(except: allowed.webDomainTokens)
    }

    static func open(_ id: Int) {
        store(id).clearAllSettings()
    }

    // MARK: When

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    static func minutes(_ hhmm: String?) -> Int? {
        let parts = (hhmm ?? "").split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// When the lock opens, if it holds at `now`: on, in its time, and not unlocked early this time.
    static func until(_ lock: ScreenLock, at now: Date = Date()) -> Date? {
        if lock.once {
            guard let start = date(lock.startsAt), let end = date(lock.endsAt), start <= now, now < end else { return nil }
            return end
        }
        guard lock.enabled, let start = minutes(lock.start), let end = minutes(lock.end) else { return nil }
        let calendar = Calendar.current
        let length = ((end - start) % 1440 + 1440) % 1440
        let today = calendar.startOfDay(for: now)
        for back in [1, 0] {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let from = calendar.date(byAdding: .minute, value: start, to: day),
                  let to = calendar.date(byAdding: .minute, value: length, to: from) else { continue }
            // Calendar's weekday is 1 = Sunday; the server's is ISO, 1 = Monday.
            let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
            guard from <= now, now < to, lock.days?.isEmpty != false || lock.days!.contains(weekday) else { continue }
            if let opened = date(lock.openUntil), opened >= to { return nil }
            return to
        }
        return nil
    }

    /// The lock that holds now and ends last: the one the shield names.
    static func current(at now: Date = Date()) -> (lock: ScreenLock, until: Date)? {
        locks.compactMap { lock in until(lock, at: now).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// The schedule DeviceActivity watches for a lock: daily for a schedule (the monitor checks the day), the exact
    /// times for a one-off. nil: nothing to watch (a schedule that's off, a one-off that's over).
    static func schedule(for lock: ScreenLock, now: Date = Date()) -> DeviceActivitySchedule? {
        if lock.once {
            guard let start = date(lock.startsAt), let end = date(lock.endsAt), end > now else { return nil }
            let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            return DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(fields, from: max(start, now)),
                                          intervalEnd: Calendar.current.dateComponents(fields, from: end), repeats: false)
        }
        guard lock.enabled, let start = minutes(lock.start), let end = minutes(lock.end) else { return nil }
        return DeviceActivitySchedule(intervalStart: DateComponents(hour: start / 60, minute: start % 60),
                                      intervalEnd: DateComponents(hour: end / 60, minute: end % 60), repeats: true)
    }
}
