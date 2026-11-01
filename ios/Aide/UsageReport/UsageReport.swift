import DeviceActivity
import ManagedSettings
import SwiftUI

/// The Screen tab's usage, drawn here because only a report extension may read which apps were used. Nothing leaves
/// it: it has no network and can't write where the app reads.
@main
struct UsageReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        UsageScene(context: .usageDay, kind: .day) { UsageReportView(data: $0) }
        UsageScene(context: .usageWeek, kind: .week) { UsageReportView(data: $0) }
        UsageScene(context: .usageMonth, kind: .month) { UsageReportView(data: $0) }
    }
}

struct UsageScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let kind: UsageKind
    let content: (UsageReportData) -> UsageReportView

    /// Every app's time, pickups and notifications by day (and by hour for a day). The period is the one around the
    /// last segment, which the app's filter ends with (`DeviceActivityFilter.usage`).
    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageReportData {
        let calendar = Calendar.current
        var days: [Date: UsageDay] = [:]
        var latest: Date?
        for await device in data {
            for await segment in device.activitySegments {
                let start = segment.dateInterval.start
                latest = max(latest ?? start, start)
                let date = calendar.startOfDay(for: start)
                var day = days[date] ?? UsageDay(date: date)
                if let first = segment.firstPickup, first < day.firstPickup ?? .distantFuture { day.firstPickup = first }
                let hour = calendar.component(.hour, from: start)
                for await category in segment.categories {
                    for await activity in category.applications {
                        let application = activity.application
                        let name = application.localizedDisplayName ?? application.bundleIdentifier ?? "An app"
                        let id = application.bundleIdentifier ?? name
                        var app: UsageApp
                        if let index = day.apps.firstIndex(where: { $0.id == id }) {
                            app = day.apps.remove(at: index)
                        } else {
                            app = UsageApp(id: id, name: name, token: application.token.flatMap { try? JSONEncoder().encode($0) })
                        }
                        app.seconds += activity.totalActivityDuration
                        app.pickups += activity.numberOfPickups
                        app.notifications += activity.numberOfNotifications
                        if kind == .day {
                            if app.hourly.count != 24 { app.hourly = Array(repeating: 0, count: 24) }
                            app.hourly[hour] += activity.totalActivityDuration
                        }
                        day.apps.append(app)
                    }
                }
                days[date] = day
            }
        }
        let period = UsageMath.period(kind, containing: latest ?? Date())
        return UsageReportData(kind: kind, days: days.values.sorted { $0.date < $1.date }, period: period)
    }
}
