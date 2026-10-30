import AppIntents
import WidgetKit

// One tap to log a limit habit (#21): "Log one" from Shortcuts, Siri and the Action Button (the app's
// shortcuts), the Health widget's + and the Control Center control (the extension). In both targets, so each
// runs it in its own process and goes straight to the server (docs/API.md, `POST /v1/habits/{id}/count`).

@MainActor private let client = APIClient(config: { AppSettings().apiConfig })

struct HabitEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Habit"
    static var defaultQuery = HabitQuery()

    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The habits you count; the others are ticked, so "Log one" isn't for them.
struct HabitQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [HabitEntity] {
        try await limitHabits().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [HabitEntity] {
        try await limitHabits()
    }

    @MainActor
    private func limitHabits() async throws -> [HabitEntity] {
        try await client.habits().filter(\.isLimit).map { HabitEntity(id: $0.id, name: $0.name) }
    }
}

struct LogHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "Log one"
    static var description = IntentDescription(
        "Adds one to a habit with a daily limit, like coffee. Put it on the Action Button for one press.")
    static var openAppWhenRun = false

    @Parameter(title: "Habit") var habit: HabitEntity

    init() {}
    init(habit: HabitEntity) { self.habit = habit }

    static var parameterSummary: some ParameterSummary { Summary("Log one \(\.$habit)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let updated = try await client.countHabit(habit.id, add: 1)
        WidgetCenter.shared.reloadTimelines(ofKind: "Health")
        WidgetCenter.shared.reloadTimelines(ofKind: "Objectives")
        let n = updated.count ?? 0
        let most = updated.cadence.max ?? 0
        let line = n > most ? "\(n) today, \(n - most) over your \(most)." : "\(n) of \(most) today."
        return .result(dialog: IntentDialog(stringLiteral: "\(updated.name): \(line)"))
    }
}
