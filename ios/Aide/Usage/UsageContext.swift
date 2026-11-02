import DeviceActivity
import SwiftUI

/// The report's pages, named the same in the app (which asks) and the extension (which draws).
extension DeviceActivityReport.Context {
    static let usageDay = Self("usage-day")
    static let usageWeek = Self("usage-week")
    static let usageMonth = Self("usage-month")
    /// Draws nothing: reads the days before today hour by hour once, so the report keeps them (`DayCache`).
    static let usageFill = Self("usage-fill")

    static func usage(_ kind: UsageKind) -> Self {
        switch kind {
        case .day: .usageDay
        case .week: .usageWeek
        case .month: .usageMonth
        }
    }
}

extension DeviceActivityFilter {
    /// The phone's use for a page: hour by hour for a day (and the 7 days before, for your usual), day by day for a
    /// week or month (and the one before). A recent day asks for itself alone: the report keeps the days before from
    /// `usageFill` (iOS hands hours over one at a time, ~1.5 s for 8 days, every time the usage changes).
    static func usage(_ kind: UsageKind, containing date: Date) -> DeviceActivityFilter {
        let calendar = Calendar.current
        let filled = calendar.date(byAdding: .day, value: UsageMath.usualDays - UsageMath.filledDays,
                                   to: calendar.startOfDay(for: Date())) ?? .distantFuture
        let asked = kind == .day && date >= filled
            ? UsageMath.period(.day, containing: date) : UsageMath.asked(kind, containing: date)
        return DeviceActivityFilter(segment: kind == .day ? .hourly(during: asked) : .daily(during: asked),
                                    users: .all, devices: .init([.iPhone]))
    }

    /// The `filledDays` before today, hour by hour, for `usageFill`.
    static var usageFill: DeviceActivityFilter {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -UsageMath.filledDays, to: today) ?? today
        return DeviceActivityFilter(segment: .hourly(during: DateInterval(start: start, end: today)),
                                    users: .all, devices: .init([.iPhone]))
    }
}
