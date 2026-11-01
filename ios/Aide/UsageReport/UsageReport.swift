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
    ///
    /// Only one phone: the filter can name a model, not this phone, so another iPhone sharing Screen Time on the same
    /// Apple ID comes too; the one used last is kept and the others are named under the list. An hour iOS hands over
    /// twice, or an app listed under two categories in one hour, is counted once.
    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageReportData {
        let calendar = Calendar.current
        var reads: [String: DeviceRead] = [:]
        var order: [String] = []
        var latest: Date?
        for await device in data {
            let name = device.device.name ?? "iPhone"
            if reads[name] == nil { reads[name] = DeviceRead(); order.append(name) }
            var read = reads[name]!
            for await segment in device.activitySegments {
                let start = segment.dateInterval.start
                latest = max(latest ?? start, start)
                guard read.seen.insert(start).inserted else { continue }
                let date = calendar.startOfDay(for: start)
                var day = read.days[date] ?? UsageDay(date: date)
                if let first = segment.firstPickup, first < day.firstPickup ?? .distantFuture { day.firstPickup = first }
                let hour = calendar.component(.hour, from: start)
                var hourApps: [String: UsageApp] = [:]
                for await category in segment.categories {
                    for await activity in category.applications {
                        let application = activity.application
                        let name = application.localizedDisplayName ?? application.bundleIdentifier ?? "An app"
                        let id = application.bundleIdentifier ?? name
                        var app = hourApps[id]
                            ?? UsageApp(id: id, name: name, token: application.token.flatMap { try? JSONEncoder().encode($0) })
                        app.seconds = max(app.seconds, activity.totalActivityDuration)
                        app.pickups = max(app.pickups, activity.numberOfPickups)
                        app.notifications = max(app.notifications, activity.numberOfNotifications)
                        hourApps[id] = app
                    }
                }
                for (id, used) in hourApps {
                    var app: UsageApp
                    if let index = day.apps.firstIndex(where: { $0.id == id }) {
                        app = day.apps.remove(at: index)
                    } else {
                        app = UsageApp(id: id, name: used.name, token: used.token)
                    }
                    app.seconds += used.seconds
                    app.pickups += used.pickups
                    app.notifications += used.notifications
                    if kind == .day {
                        if app.hourly.count != 24 { app.hourly = Array(repeating: 0, count: 24) }
                        app.hourly[hour] += used.seconds
                    }
                    day.apps.append(app)
                    if used.seconds > 0 { read.lastUsed = max(read.lastUsed ?? start, start) }
                }
                read.days[date] = day
            }
            reads[name] = read
        }
        let kept = order.max { (reads[$0]?.lastUsed ?? .distantPast) < (reads[$1]?.lastUsed ?? .distantPast) }
        let days = kept.flatMap { reads[$0]?.days.values }.map { Array($0) } ?? []
        let period = UsageMath.period(kind, containing: latest ?? Date())
        return UsageReportData(kind: kind, days: days.sorted { $0.date < $1.date }, period: period,
                               device: order.count > 1 ? kept : nil, leftOut: order.filter { $0 != kept })
    }
}

/// One device's days, while the report reads.
private struct DeviceRead {
    var days: [Date: UsageDay] = [:]
    var seen: Set<Date> = []
    var lastUsed: Date?
}
