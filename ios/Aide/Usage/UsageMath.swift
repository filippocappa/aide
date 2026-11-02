import Foundation

/// One app's use over a day or a period: the time, the pickups that opened it first, its notifications, and (on a day)
/// the time in each hour.
struct UsageApp: Identifiable, Hashable {
    /// The bundle ID, else the name.
    let id: String
    var name: String
    var seconds: TimeInterval = 0
    var pickups = 0
    var notifications = 0
    /// 24 hours, on a day read hour by hour; empty otherwise.
    var hourly: [TimeInterval] = []
    /// Apple's token for the app (JSON), which draws its icon in the report; nil in sample data.
    var token: Data?
}

/// A website's time (the Mac only: the phone's report can't see sites), part of its browser's time, not added to the
/// total again.
struct UsageSite: Identifiable, Hashable {
    /// The site, "youtube.com".
    let id: String
    var seconds: TimeInterval = 0
    /// 24 hours, on a day; empty otherwise.
    var hourly: [TimeInterval] = []
    /// Its time in each browser, by bundle ID.
    var browsers: [String: TimeInterval] = [:]
}

/// What the Screen tab shows: a day, a week (Monday to Sunday) or a month.
enum UsageKind: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
}

/// A day's use, every app's time added up: Apple's own total counts time it can't put on an app and overlaps, so
/// Aide's total is the apps' sum, the same number as the list under it.
struct UsageDay: Identifiable, Hashable {
    /// Midnight, local.
    let date: Date
    var apps: [UsageApp] = []
    /// The websites seen in browsers (the Mac only).
    var sites: [UsageSite] = []
    /// When the phone was first picked up that day.
    var firstPickup: Date?
    /// The apps' own times added up before they were cut to iOS's, and iOS's own total (the phone's report only;
    /// a check against Settings → Screen Time in debug builds).
    var added: TimeInterval = 0
    var reported: TimeInterval = 0

    var id: Date { date }
    var total: TimeInterval { apps.reduce(0) { $0 + $1.seconds } }
    var pickups: Int { apps.reduce(0) { $0 + $1.pickups } }
    var notifications: Int { apps.reduce(0) { $0 + $1.notifications } }

    /// The apps' time in each of the 24 hours (all zero on a day read as a whole).
    var hourly: [TimeInterval] {
        var hours = Array(repeating: TimeInterval(0), count: 24)
        for app in apps where app.hourly.count == 24 {
            for h in 0..<24 { hours[h] += app.hourly[h] }
        }
        return hours
    }

    /// Most used first.
    var ranked: [UsageApp] { apps.filter { $0.seconds >= 1 }.sorted { $0.seconds > $1.seconds } }

    /// Time used before `time` of day (its hours, the current one in proportion), for "so far" against other days.
    func total(before time: TimeInterval) -> TimeInterval {
        let hours = hourly
        guard hours.contains(where: { $0 > 0 }) else { return total }
        var sum: TimeInterval = 0
        for h in 0..<24 {
            let start = TimeInterval(h) * 3600
            if time >= start + 3600 { sum += hours[h] } else if time > start { sum += hours[h] * (time - start) / 3600 }
        }
        return sum
    }

    func pickups(before time: TimeInterval) -> Double {
        let all = total
        return all > 0 ? Double(pickups) * total(before: time) / all : Double(pickups)
    }

    /// Minutes used between 23:00 and 06:00 (that day's early morning and its late evening).
    var nightSeconds: TimeInterval {
        let hours = hourly
        return (0..<6).reduce(0) { $0 + hours[$1] } + hours[23]
    }
}

/// The page's numbers, worked out the same way for the report and the tests.
enum UsageMath {
    /// How many days before a day make "your usual".
    static let usualDays = 14

    /// The days before `day` with any use, newest first, up to `usualDays`.
    static func history(before day: UsageDay, in days: [UsageDay]) -> [UsageDay] {
        Array(days.filter { $0.date < day.date && $0.total > 0 }.sorted { $0.date > $1.date }.prefix(usualDays))
    }

    /// Your usual by `time` of day (the whole day when nil): the average of the days before. nil under 3 days.
    static func usual(before day: UsageDay, in days: [UsageDay], by time: TimeInterval? = nil) -> TimeInterval? {
        let past = history(before: day, in: days)
        guard past.count >= 3 else { return nil }
        return past.reduce(0) { $0 + (time.map($1.total(before:)) ?? $1.total) } / Double(past.count)
    }

    static func usualPickups(before day: UsageDay, in days: [UsageDay], by time: TimeInterval? = nil) -> Double? {
        let past = history(before: day, in: days)
        guard past.count >= 3 else { return nil }
        return past.reduce(0) { $0 + (time.map($1.pickups(before:)) ?? Double($1.pickups)) } / Double(past.count)
    }

    /// Seconds since midnight for today (now), nil for a day that's over.
    static func timeOfDay(_ day: UsageDay, now: Date = Date()) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(day.date)
        return elapsed >= 0 && elapsed < 86400 ? elapsed : nil
    }

    /// Time off the phone since the first pickup: until now today, else until the end of the last hour used.
    static func offline(_ day: UsageDay, now: Date = Date()) -> TimeInterval? {
        guard let first = day.firstPickup else { return nil }
        let end: Date
        if let time = timeOfDay(day, now: now) {
            end = day.date.addingTimeInterval(time)
        } else if let last = day.hourly.lastIndex(where: { $0 > 0 }) {
            end = day.date.addingTimeInterval(TimeInterval(last + 1) * 3600)
        } else {
            return nil
        }
        return max(0, end.timeIntervalSince(first) - day.total)
    }

    // MARK: Focus

    /// The day's focus, 0–100, and what it's made of.
    struct Focus: Hashable {
        struct Part: Hashable {
            let name: String
            let score: Int
            /// Its share of the score, 0–1.
            let weight: Double
            let detail: String
        }
        let score: Int
        let parts: [Part]
    }

    /// A full day's screen time that still scores well: 3 hours.
    static let dayBudget: TimeInterval = 3 * 3600

    /// Four parts: how much (against 3 hours a day, or the share of it by now), against your usual by this time,
    /// pickups against your usual, and use at night (23:00–06:00). Without 3 days of history, the first and last.
    static func focus(_ day: UsageDay, in days: [UsageDay], now: Date = Date()) -> Focus {
        let time = timeOfDay(day, now: now)
        let total = day.total
        // The budget by now: none of it before 07:00, all of it by 23:00.
        let share = time.map { min(1, max(0.1, ($0 - 7 * 3600) / (16 * 3600))) } ?? 1
        let budget = dayBudget * share
        let amount = clamp(100 - max(0, total / budget - 0.5) * 66.7)
        var parts = [Focus.Part(name: "How much", score: amount, weight: 0.45,
                                detail: "\(duration(total)) of a \(duration(budget)) budget\(time == nil ? "" : " by now")")]
        if let usual = usual(before: day, in: days, by: time), usual > 0 {
            let s = clamp(100 - max(0, total / usual - 0.7) * 100)
            parts.append(.init(name: "Against your usual", score: s, weight: 0.25,
                               detail: "\(duration(usual)) usually\(time == nil ? "" : " by now")"))
        }
        if let usual = usualPickups(before: day, in: days, by: time), usual > 0 {
            let s = clamp(100 - max(0, Double(day.pickups) / usual - 0.7) * 100)
            parts.append(.init(name: "Pickups", score: s, weight: 0.15,
                               detail: "\(day.pickups), \(Int(usual.rounded())) usually"))
        }
        let night = day.nightSeconds
        parts.append(.init(name: "At night", score: clamp(100 - night / 60 * 100 / 60), weight: 0.15,
                           detail: night < 60 ? "None between 23:00 and 06:00" : "\(duration(night)) between 23:00 and 06:00"))
        let weights = parts.reduce(0) { $0 + $1.weight }
        let score = parts.reduce(0) { $0 + Double($1.score) * $1.weight } / weights
        return Focus(score: Int(score.rounded()), parts: parts)
    }

    private static func clamp(_ x: Double) -> Int { Int(min(100, max(0, x)).rounded()) }

    // MARK: Periods

    /// The day, week or month around `date`.
    static func period(_ kind: UsageKind, containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let unit: Calendar.Component = kind == .day ? .day : kind == .week ? .weekOfYear : .month
        return calendar.dateInterval(of: unit, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86400)
    }

    /// What the report asks for: the period and, before it, what it's compared with (the 14 days before a day, the
    /// week or month before).
    static func asked(_ kind: UsageKind, containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let period = period(kind, containing: date, calendar: calendar)
        let start: Date = switch kind {
        case .day: calendar.date(byAdding: .day, value: -usualDays, to: period.start) ?? period.start
        case .week: calendar.date(byAdding: .day, value: -7, to: period.start) ?? period.start
        case .month: calendar.date(byAdding: .month, value: -1, to: period.start) ?? period.start
        }
        return DateInterval(start: start, end: period.end)
    }

    /// The period's days, midnight each.
    static func days(of period: DateInterval, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: period.start)
        while day < period.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Every app over `days`, added up, most used first.
    static func merged(_ days: [UsageDay]) -> [UsageApp] {
        var apps: [String: UsageApp] = [:]
        for day in days {
            for app in day.apps {
                var sum = apps[app.id] ?? UsageApp(id: app.id, name: app.name, token: app.token)
                sum.seconds += app.seconds
                sum.pickups += app.pickups
                sum.notifications += app.notifications
                apps[app.id] = sum
            }
        }
        return apps.values.filter { $0.seconds >= 1 }.sorted { $0.seconds > $1.seconds }
    }

    /// The websites of some days added up, most used first.
    static func mergedSites(_ days: [UsageDay]) -> [UsageSite] {
        var sites: [String: UsageSite] = [:]
        for day in days {
            for site in day.sites {
                var sum = sites[site.id] ?? UsageSite(id: site.id)
                sum.seconds += site.seconds
                for (browser, seconds) in site.browsers { sum.browsers[browser, default: 0] += seconds }
                sites[site.id] = sum
            }
        }
        return sites.values.filter { $0.seconds >= 1 }.sorted { $0.seconds > $1.seconds }
    }

    /// The days an average is taken over: the whole days that are over, or today alone while it's the only one
    /// (half a day would pull a week's average down).
    static func averaged(_ days: [UsageDay], now: Date = Date(), calendar: Calendar = .current) -> [UsageDay] {
        let begun = days.filter { $0.date <= now }
        let over = begun.filter { $0.date < calendar.startOfDay(for: now) }
        return over.isEmpty ? begun : over
    }

    /// The average a day (see `averaged`), nil when no day has begun.
    static func average(_ days: [UsageDay], now: Date = Date()) -> TimeInterval? {
        let counted = averaged(days, now: now)
        return counted.isEmpty ? nil : counted.reduce(0) { $0 + $1.total } / Double(counted.count)
    }

    // MARK: Words

    /// "4h 12m", "38m", "0m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
