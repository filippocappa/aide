import DeviceActivity
import SwiftUI

/// The report's pages, named the same in the app (which asks) and the extension (which draws).
extension DeviceActivityReport.Context {
    static let usageDay = Self("usage-day")
    static let usageWeek = Self("usage-week")
    static let usageMonth = Self("usage-month")

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
    /// week or month (and the one before).
    static func usage(_ kind: UsageKind, containing date: Date) -> DeviceActivityFilter {
        let asked = UsageMath.asked(kind, containing: date)
        return DeviceActivityFilter(segment: kind == .day ? .hourly(during: asked) : .daily(during: asked),
                                    users: .all, devices: .init([.iPhone]))
    }
}
