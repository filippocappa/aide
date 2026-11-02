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
    /// Each segment's apps are cut down to iOS's own time for it when they add up to more (two apps on screen at once
    /// would count twice).
    ///
    /// Only one phone: the filter can name a model, not this phone, so another iPhone sharing Screen Time on the same
    /// Apple ID comes too; the one used last is kept and the others are named under the list. An hour iOS hands over
    /// twice, or an app listed under two categories in one hour, is counted once.
    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageReportData {
        let calendar = Calendar.current
        #if DEBUG
        let started = Date()
        var firstAt: Date?
        var segments = 0
        UsageProbe.calls += 1
        #endif
        var reads: [String: DeviceRead] = [:]
        var order: [String] = []
        var latest: Date?
        var tokens: [String: Data?] = [:]  // each app's token, encoded once
        for await device in data {
            let name = device.device.name ?? "iPhone"
            if reads[name] == nil { reads[name] = DeviceRead(); order.append(name) }
            var read = reads[name]!
            for await segment in device.activitySegments {
                #if DEBUG
                if firstAt == nil { firstAt = Date() }
                segments += 1
                #endif
                let start = segment.dateInterval.start
                latest = max(latest ?? start, start)
                guard read.seen.insert(start).inserted else { continue }
                let date = calendar.startOfDay(for: start)
                var day = read.days[date] ?? UsageDay(date: date)
                if let first = segment.firstPickup, first < day.firstPickup ?? .distantFuture { day.firstPickup = first }
                let hour = calendar.component(.hour, from: start)
                // iOS's own time for the segment, which counts two apps on screen at once (a video in picture in
                // picture, a call) once; the apps' own times would count it twice.
                let reported = segment.totalActivityDuration
                var hourApps: [String: UsageApp] = [:]
                for await category in segment.categories {
                    for await activity in category.applications {
                        let application = activity.application
                        let name = application.localizedDisplayName ?? application.bundleIdentifier ?? "An app"
                        let id = application.bundleIdentifier ?? name
                        if tokens[id] == nil { tokens[id] = application.token.flatMap { try? JSONEncoder().encode($0) } }
                        var app = hourApps[id] ?? UsageApp(id: id, name: name, token: tokens[id] ?? nil)
                        app.seconds = max(app.seconds, activity.totalActivityDuration)
                        app.pickups = max(app.pickups, activity.numberOfPickups)
                        app.notifications = max(app.notifications, activity.numberOfNotifications)
                        hourApps[id] = app
                    }
                }
                // The apps' times, cut down to iOS's own when they add up to more (never raised: iOS's total also
                // holds time it can't put on an app).
                let added = hourApps.values.reduce(0) { $0 + $1.seconds }
                let share = reported > 0 && added > reported ? reported / added : 1
                day.added += added
                day.reported += reported
                for (id, found) in hourApps {
                    var used = found
                    used.seconds *= share
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
        var report = UsageReportData(kind: kind, days: days.sorted { $0.date < $1.date }, period: period,
                                     device: order.count > 1 ? kept : nil, leftOut: order.filter { $0 != kept })
        #if DEBUG
        let first = firstAt.map { String(format: "%.1f", $0.timeIntervalSince(started)) } ?? "–"
        report.debug = "first segment \(first)s · all \(String(format: "%.1f", Date().timeIntervalSince(started)))s · "
            + "\(segments) segments · call \(UsageProbe.calls), process \(Int(Date().timeIntervalSince(UsageProbe.launched)))s · "
            + UsageProbe.disk()
        #endif
        return report
    }
}

#if DEBUG
/// Debug builds: whether the extension's process lives on between reports and whether it can write a file.
private enum UsageProbe {
    static let launched = Date()
    static var calls = 0

    static func disk() -> String {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return "no caches" }
        let url = dir.appendingPathComponent("probe.txt")
        let last = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Double.init)
            .map { "last write \(Int(Date().timeIntervalSince1970 - $0))s ago" } ?? "nothing saved yet"
        do {
            try "\(Date().timeIntervalSince1970)".write(to: url, atomically: true, encoding: .utf8)
            return "disk ok, \(last)"
        } catch {
            return "disk refused (\((error as NSError).code)), \(last)"
        }
    }
}
#endif

/// One device's days, while the report reads.
private struct DeviceRead {
    var days: [Date: UsageDay] = [:]
    var seen: Set<Date> = []
    var lastUsed: Date?
}
