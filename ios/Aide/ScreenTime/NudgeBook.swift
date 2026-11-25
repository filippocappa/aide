import DeviceActivity
import FamilyControls
import Foundation
import UserNotifications

/// The phone's nudges (#84, docs/API.md "Nudges"), only while it's in use. The app writes tonight's bedtime steps and
/// the next focus events here (from `GET /v1/nudges`) and has DeviceActivity watch them; the monitor posts the
/// notification when a threshold says the phone is being used:
/// - **Bedtime:** one activity from the first step to the last, an event every 2 minutes of use (anything counted);
///   each firing shows the step due now, once. Snooze 10 min and I'm going (20 min) quiet it.
/// - **Off task:** an activity per study or `#focus` event with the Work list's apps: a minute of them, then 16,
///   then 31: the `lock` step (unless the second was answered Back to it), for which the server makes a 15-minute
///   lock on the Work list; it reaches the phone when the app sends the step and syncs. Back to it opens the course.
/// Quiet during a focus round, and for bedtime while another timed event is on. A phone can't tell a call from here,
/// nor name the app: the notification says the event, not the app. What's shown waits in `pending` for the app to
/// send (`ScreenTimeService`).
enum NudgeBook {
    private static let defaults: UserDefaults? = (Bundle.main.object(forInfoDictionaryKey: "AideAppGroup") as? String)
        .flatMap { $0.isEmpty || $0.contains("$(") ? nil : UserDefaults(suiteName: $0) }

    struct Step: Codable, Hashable {
        let step: String
        let at: Date
        let until: Date
        let title: String
        let body: String
    }

    struct Night: Codable, Hashable {
        /// The morning the night ends on.
        let date: String
        let steps: [Step]
    }

    /// A focus event watched for the Work list's apps.
    struct Watch: Codable, Hashable {
        let activity: String
        let title: String
        let start: Date
        let end: Date
        let startISO: String
        let endISO: String
        let courseID: Int?
    }

    /// A nudge shown (or answered), until the app sends it.
    struct Pending: Codable, Hashable {
        let key: String
        let kind: String
        let step: String
        let at: String
        var night: String?
        var event: String?
        var eventStart: String?
        var eventEnd: String?
        var courseID: Int?
        var answer: String?
    }

    static var night: Night? {
        get { read("nudgeNight") }
        set { write(newValue, "nudgeNight") }
    }

    static var watches: [Watch] {
        get { read("nudgeWatches") ?? [] }
        set { write(newValue, "nudgeWatches") }
    }

    /// Other timed events (not study, not #focus): bedtime stays quiet while one is on.
    static var others: [DateInterval] {
        get { read("nudgeOthers") ?? [] }
        set { write(newValue, "nudgeOthers") }
    }

    static var quietUntil: Date {
        get { defaults?.object(forKey: "nudgeQuietUntil") as? Date ?? .distantPast }
        set { defaults?.set(newValue, forKey: "nudgeQuietUntil") }
    }

    static var shown: [String: Date] {
        get { read("nudgeShown") ?? [:] }
        set { write(newValue, "nudgeShown") }
    }

    static var pending: [Pending] {
        get { read("nudgePending") ?? [] }
        set { write(newValue, "nudgePending") }
    }

    /// Focus events (their start) whose second nudge was answered Back to it: no lock step for them.
    static var backAfterAgain: [String: Date] {
        get { read("nudgeBackAfterAgain") ?? [:] }
        set { write(newValue, "nudgeBackAfterAgain") }
    }

    private static func read<T: Decodable>(_ key: String) -> T? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func write<T: Encodable>(_ value: T?, _ key: String) {
        defaults?.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    // MARK: Activities

    static let bedtimeActivity = DeviceActivityName("nudge-bedtime")
    static func watchActivity(_ i: Int) -> DeviceActivityName { DeviceActivityName("nudge-offtask-\(i)") }
    static func isNudge(_ name: String) -> Bool { name.hasPrefix("nudge-") }

    /// Minutes of use the bedtime activity fires at: every 2 from 1, through the evening's three hours and more.
    static let useSteps = Array(stride(from: 1, through: 249, by: 2))
    static func useEvent(_ minutes: Int) -> DeviceActivityEvent.Name { .init("nudge-use-\(minutes)") }
    static let first = DeviceActivityEvent.Name("nudge-first")
    static let again = DeviceActivityEvent.Name("nudge-again")
    static let againMinutes = 16
    static let lock = DeviceActivityEvent.Name("nudge-lock")
    static let lockMinutes = 31

    /// `minutes` of use of `selection` since the activity began (not earlier in the day).
    static func use(_ selection: FamilyActivitySelection, minutes: Int) -> DeviceActivityEvent {
        DeviceActivityEvent(applications: selection.applicationTokens, categories: selection.categoryTokens,
                            webDomains: selection.webDomainTokens,
                            threshold: DateComponents(hour: minutes / 60, minute: minutes % 60))
    }

    /// A one-off schedule from `start` (now at the earliest) to `end`, at least the 15 minutes DeviceActivity takes.
    static func schedule(_ start: Date, _ end: Date, now: Date = Date()) -> DeviceActivitySchedule? {
        let from = max(start, now)
        let to = max(end, from.addingTimeInterval(15 * 60 + 30))
        guard end > now else { return nil }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(fields, from: from),
                                      intervalEnd: Calendar.current.dateComponents(fields, from: to), repeats: false)
    }

    // MARK: The monitor

    /// A threshold reached in a nudge activity: the phone's in use. Shows what's due, once.
    static func fired(_ event: DeviceActivityEvent.Name, in activity: DeviceActivityName, now: Date = Date()) {
        // A focus round shields all but the focus apps already.
        guard !LockBook.locks.contains(where: { $0.focus != nil && LockClock.until($0, at: now) != nil }) else { return }
        if activity == bedtimeActivity {
            guard now >= quietUntil, !others.contains(where: { $0.contains(now) }), let night,
                  let step = night.steps.first(where: { $0.at <= now && now < $0.until }) else { return }
            let key = "phone-bedtime-\(night.date)-\(step.step)-\(Int(step.at.timeIntervalSince1970))"
            show(key, title: step.title, body: step.body, category: "nudge-bedtime", url: nil, now: now,
                 Pending(key: key, kind: "bedtime", step: step.step, at: iso(now), night: night.date))
            return
        }
        guard let watch = watches.first(where: { $0.activity == activity.rawValue }),
              watch.start.addingTimeInterval(-60) <= now, now < watch.end else { return }
        let step = event == lock ? "lock" : event == again ? "again" : "first"
        let key = "phone-offtask-\(watch.startISO)-\(step)"
        let until = clock(watch.end)
        if step == "lock" {
            guard backAfterAgain[watch.startISO] == nil else { return }
            show(key, title: "Locked for 15 min", body: "Back to \(watch.title): it runs until \(until).",
                 category: "nudge-locked", url: watch.courseID.map { "aide://study/\($0)" }, now: now,
                 Pending(key: key, kind: "offtask", step: step, at: iso(now), event: watch.title,
                         eventStart: watch.startISO, eventEnd: watch.endISO, courseID: watch.courseID))
            return
        }
        let body = step == "first"
            ? "The calendar says \(watch.title) until \(until), and this is on your Work list."
            : "Still on your Work list; \(watch.title) runs until \(until)."
        show(key, title: step == "first" ? "Off task" : "Still off task", body: body, category: "nudge-offtask",
             url: watch.courseID.map { "aide://study/\($0)" }, now: now,
             Pending(key: key, kind: "offtask", step: step, at: iso(now), event: watch.title,
                     eventStart: watch.startISO, eventEnd: watch.endISO, courseID: watch.courseID))
    }

    private static func show(_ key: String, title: String, body: String, category: String, url: String?, now: Date,
                             _ log: Pending) {
        var seen = shown
        guard seen[key] == nil else { return }
        seen[key] = now
        shown = seen.filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        pending = (pending + [log]).suffix(100)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = "nudges"
        content.userInfo = ["nudge": key, "kind": log.kind, "step": log.step, "url": url ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    // MARK: Answers (the app)

    static let snooze = "nudge-snooze"
    static let going = "nudge-going"
    static let back = "nudge-back"
    static let notNow = "nudge-not-now"

    static var categories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: "nudge-bedtime", actions: [
                UNNotificationAction(identifier: snooze, title: "Snooze 10 min"),
                UNNotificationAction(identifier: going, title: "I'm going"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "nudge-offtask", actions: [
                UNNotificationAction(identifier: back, title: "Back to it", options: [.foreground]),
                UNNotificationAction(identifier: notNow, title: "Not now"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "nudge-locked", actions: [
                UNNotificationAction(identifier: back, title: "Back to it", options: [.foreground]),
            ], intentIdentifiers: []),
        ]
    }

    /// The answer a notification action gives (nil: a plain tap or a dismiss), quiet set for bedtime's, and kept to send.
    static func answer(_ userInfo: [AnyHashable: Any], action: String, now: Date = Date()) -> Pending? {
        guard let key = userInfo["nudge"] as? String, let kind = userInfo["kind"] as? String,
              let step = userInfo["step"] as? String else { return nil }
        let answer: String
        switch action {
        case snooze: answer = "snooze"; quietUntil = now.addingTimeInterval(10 * 60)
        case going: answer = "going"; quietUntil = now.addingTimeInterval(20 * 60)
        case back: answer = "back"
        case UNNotificationDefaultActionIdentifier where kind == "offtask": answer = "back"
        case notNow: answer = "not_now"
        default: return nil
        }
        let prefix = "phone-offtask-", suffix = "-again"
        if answer == "back", kind == "offtask", step == "again", key.hasPrefix(prefix), key.hasSuffix(suffix) {
            let start = String(key.dropFirst(prefix.count).dropLast(suffix.count)) // the event's start
            backAfterAgain = backAfterAgain.merging([start: now]) { $1 }
                .filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        }
        let log = Pending(key: key, kind: kind, step: step, at: iso(now), answer: answer)
        pending = (pending + [log]).suffix(100)
        return log
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }
}
