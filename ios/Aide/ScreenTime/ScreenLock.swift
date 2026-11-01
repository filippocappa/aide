import Foundation

/// A Screen Time lock (docs/API.md, "Screen Time"), as the server sends it. Dates are ISO strings with an offset.
struct ScreenLock: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    /// A one-off, from `startsAt` to `endsAt`; else a schedule, `start` to `end` on `days`.
    let once: Bool
    /// HH:MM local; an `end` before the `start` is the next morning.
    let start: String?
    let end: String?
    /// ISO weekdays it starts on, [] every day. nil on a one-off.
    let days: [Int]?
    let startsAt: String?
    let endsAt: String?
    var enabled: Bool
    /// Ends early only with an emergency pass; while it's on, the Screen Time page is locked. nil from an older server.
    let strict: Bool?
    /// Who set it ("coach"); nil: you, in the app.
    let agent: String?
    /// On now, until `until`.
    let locked: Bool
    let until: String?
    /// Unlocked early this time, open until then.
    let openUntil: String?
    let next: String?
    let summary: String

    var isStrict: Bool { strict == true }
}

/// A daily app limit (docs/API.md, "Daily app limits"): its apps get `minutes` a day, then lock until midnight. Which
/// apps lives on this phone only (`LockBook.limitApps`); the server has the title the user typed.
struct ScreenLimit: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let minutes: Int
    /// ISO weekdays it counts on; empty, every day.
    let days: [Int]
    let enabled: Bool
    let strict: Bool
    /// When it was reached today (ISO), from the phone's last upload.
    let reached: String?
    let reachedToday: Bool
    /// Ended early for today: open until midnight.
    let openToday: Bool
    let summary: String

    /// Whether it counts on the day of `date`.
    func counts(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return days.isEmpty || days.contains(weekday == 1 ? 7 : weekday - 1)
    }
}
