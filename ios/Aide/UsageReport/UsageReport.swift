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
        UsageScene(context: .usageFill, kind: .day) { _ in EmptyView() }
    }
}

struct UsageScene<Content: View>: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let kind: UsageKind
    let content: (UsageReportData) -> Content

    /// Every app's time, pickups and notifications by day (and by hour for a day). The period is the one around the
    /// last segment, which the app's filter ends with (`DeviceActivityFilter.usage`).
    ///
    /// Each segment's apps are cut down to iOS's own time for it when they add up to more (two apps on screen at once
    /// would count twice).
    ///
    /// Days that are over are worked out once and kept (`DayCache`): their hours are skipped after that, so a report
    /// counts only today's (iOS asks again every time the usage changes, often several times a minute).
    ///
    /// Only one phone: the filter can name a model, not this phone, so another iPhone sharing Screen Time on the same
    /// Apple ID comes too; the one used last is kept and the others are named under the list. An hour iOS hands over
    /// twice, or an app listed under two categories in one hour, is counted once.
    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageReportData {
        let calendar = Calendar.current
        let hourly = kind == .day
        var reads: [String: DeviceRead] = [:]
        var order: [String] = []
        var latest: Date?
        var tokens: [String: Data?] = [:]  // each app's token, encoded once
        for await device in data {
            let name = device.device.name ?? "iPhone"
            if reads[name] == nil { reads[name] = DeviceRead(); order.append(name) }
            var read = reads[name]!
            for await segment in device.activitySegments {
                let start = segment.dateInterval.start
                latest = max(latest ?? start, start)
                let date = calendar.startOfDay(for: start)
                if read.cached.contains(date) { continue }
                if read.days[date] == nil, DayCache.isOver(date),
                   let saved = DayCache.read(hourly: hourly, device: name, date: date) {
                    read.days[date] = saved.day
                    read.cached.insert(date)
                    if let used = saved.lastUsed { read.lastUsed = max(read.lastUsed ?? used, used) }
                    continue
                }
                guard read.seen.insert(start).inserted else { continue }
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
                    if used.seconds > 0 {
                        read.lastUsed = max(read.lastUsed ?? start, start)
                        read.lastUsedOn[date] = max(read.lastUsedOn[date] ?? start, start)
                    }
                }
                read.days[date] = day
            }
            for (date, day) in read.days where !read.cached.contains(date) && DayCache.isOver(date) {
                DayCache.write(SavedDay(day: day, lastUsed: read.lastUsedOn[date]), hourly: hourly, device: name)
                read.cached.insert(date)
            }
            reads[name] = read
        }
        let kept = order.max { (reads[$0]?.lastUsed ?? .distantPast) < (reads[$1]?.lastUsed ?? .distantPast) }
        var days = kept.flatMap { reads[$0]?.days.values }.map { Array($0) } ?? []
        // A recent day comes alone (`DeviceActivityFilter.usage`): the week before, for your usual, from what's kept.
        if hourly, let kept, let latest {
            let day = calendar.startOfDay(for: latest)
            for back in 1...UsageMath.usualDays {
                guard let date = calendar.date(byAdding: .day, value: -back, to: day),
                      !days.contains(where: { $0.date == date }),
                      let saved = DayCache.read(hourly: true, device: kept, date: date) else { continue }
                days.append(saved.day)
            }
        }
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
    /// When an app was last used on each day, kept with the day.
    var lastUsedOn: [Date: Date] = [:]
    /// The days that came from `DayCache` (their segments are skipped).
    var cached: Set<Date> = []
}

/// A day that's over, as worked out once, and when an app was last used in it (which picks the phone).
struct SavedDay: Codable {
    var day: UsageDay
    var lastUsed: Date?
}

/// Days that are over, worked out once and kept in the extension's own caches folder (a JSON file a day, a few KB)
/// and in memory while the extension runs: hour by hour for the Day page, whole days for Week and Month. Kept 130
/// days; iOS may clear the folder, and then they're worked out again. It never leaves the extension.
enum DayCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: SavedDay] = [:]

    private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("usage-days-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-130 * 86400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < old { try? FileManager.default.removeItem(at: url) }
        }
        return folder
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Over, and a couple of hours past, so iOS has handed in its last hour.
    static func isOver(_ date: Date) -> Bool {
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return false }
        return end.addingTimeInterval(2 * 3600) < Date()
    }

    private static func key(hourly: Bool, device: String, date: Date) -> String {
        let phone = String(String.UnicodeScalarView(device.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        return "\(hourly ? "h" : "d")-\(phone)-\(dayFormat.string(from: date))"
    }

    static func read(hourly: Bool, device: String, date: Date) -> SavedDay? {
        let key = key(hourly: hourly, device: device, date: date)
        lock.lock()
        defer { lock.unlock() }
        if let saved = memory[key] { return saved }
        guard let url = folder?.appendingPathComponent(key + ".json"), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedDay.self, from: data), saved.day.date == date else { return nil }
        memory[key] = saved
        return saved
    }

    static func write(_ saved: SavedDay, hourly: Bool, device: String) {
        let key = key(hourly: hourly, device: device, date: saved.day.date)
        lock.lock()
        defer { lock.unlock() }
        memory[key] = saved
        if let url = folder?.appendingPathComponent(key + ".json"), let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
