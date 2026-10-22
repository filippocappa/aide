import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case wake, daily, evening, weekly, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wake: "Wake-up"; case .daily: "Morning"; case .evening: "Evening"; case .weekly: "Week"; case .monthly: "Month"
            }
        }
    }

    @Published var kind: Kind = .daily
    /// The digest sheet is up (from the chat header, the Details link or a reminder notification).
    @Published var isPresented = false
    @Published private(set) var digest: Digest?
    @Published private(set) var isLoading = false
    /// True once any digest has loaded, so the picker stays when one period has none yet.
    @Published private(set) var hasDigests = false
    /// Habits ticked here, newer than the digest's snapshot.
    @Published private(set) var habitOverrides: [Int: Habit] = [:]
    /// Objectives ticked or accepted here, newer than the digest's snapshot.
    @Published private(set) var objectiveOverrides: [String: Objective] = [:]
    /// Reminders ticked here, by server id, until the next load shows the synced state.
    @Published private(set) var reminderOverrides: [String: Bool] = [:]

    /// Set by AppEnvironment: ticks a reminder in Apple Reminders and syncs. Returns false if it couldn't.
    var completeReminder: ((Reminder, Bool) async -> Bool)?

    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            digest = try await api.digest(kind: kind.rawValue)
            hasDigests = true
            habitOverrides = [:]
            reminderOverrides = [:]
            objectiveOverrides = [:]
        } catch {
            digest = nil // 404 until the first digest exists; the empty chat falls back to suggestions
        }
    }

    func setCompleted(_ reminder: Reminder, _ done: Bool) async {
        reminderOverrides[reminder.id] = done // tick at once; undone below if it didn't work
        if await completeReminder?(reminder, done) != true { reminderOverrides[reminder.id] = nil }
    }

    func tick(_ objective: Objective) async {
        let current = objectiveOverrides[objective.id] ?? objective
        if let updated = try? await api.updateObjective(objective.id, ObjectivePatch(done: !current.done)) {
            objectiveOverrides[objective.id] = updated
        }
    }

    func accept(_ proposals: [Objective], period: String, date: String) async {
        guard let block = try? await api.acceptObjectives(period: period, date: date, ids: proposals.map(\.id)) else { return }
        for o in block.objectives where proposals.contains(where: { $0.id == o.id }) { objectiveOverrides[o.id] = o }
    }

    func toggle(_ habit: Habit) async {
        let current = habitOverrides[habit.id] ?? habit
        if let updated = try? await api.checkHabit(habit.id, done: !current.doneToday) {
            habitOverrides[habit.id] = updated
        }
    }
}
