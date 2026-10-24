import AppIntents
import WidgetKit

// Taps on a widget's tick boxes. They run in the extension and go straight to the server; WidgetKit then reloads
// the widget, which reads the server again.

struct CompleteReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a reminder"
    static var isDiscoverable = false

    @Parameter(title: "Reminder") var id: String

    init() {}
    init(id: String) { self.id = id }

    /// The server marks it and sends a silent sync, so the app ticks it in Apple Reminders too.
    func perform() async throws -> some IntentResult {
        _ = try await WidgetAPI.client.completeReminder(id)
        return .result()
    }
}

struct CheckHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "Check in a habit"
    static var isDiscoverable = false

    @Parameter(title: "Habit") var id: Int
    @Parameter(title: "Done") var done: Bool

    init() {}
    init(id: Int, done: Bool) { (self.id, self.done) = (id, done) }

    func perform() async throws -> some IntentResult {
        _ = try await WidgetAPI.client.checkHabit(id, done: done)
        WidgetCenter.shared.reloadTimelines(ofKind: "Objectives") // a check-in can tick an objective
        return .result()
    }
}

struct TickObjectiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick an objective"
    static var isDiscoverable = false

    @Parameter(title: "Objective") var id: String
    @Parameter(title: "Done") var done: Bool

    init() {}
    init(id: String, done: Bool) { (self.id, self.done) = (id, done) }

    func perform() async throws -> some IntentResult {
        _ = try await WidgetAPI.client.updateObjective(id, ObjectivePatch(done: done))
        return .result()
    }
}
