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
    /// Drafts answered here: "sent" or "dismissed", by id, until the next load drops them.
    @Published private(set) var draftOutcomes: [Int: String] = [:]

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
            draftOutcomes = [:]
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
        if let updated = try? await api.tickObjective(current) {
            objectiveOverrides[objective.id] = updated
        }
    }

    func accept(_ proposals: [Objective], period: String, date: String) async {
        guard let block = try? await api.acceptObjectives(period: period, date: date, ids: proposals.map(\.id)) else { return }
        for o in block.objectives where proposals.contains(where: { $0.id == o.id }) { objectiveOverrides[o.id] = o }
    }

    /// A problem to show, or nil once it's sent.
    func send(_ draft: MailDraft, body: String) async -> String? {
        do {
            _ = try await api.sendDraft(draft.id, body: body)
            draftOutcomes[draft.id] = "sent"
            return nil
        } catch { return error.localizedDescription }
    }

    func dismiss(_ draft: MailDraft) async -> String? {
        do {
            try await api.dismissDraft(draft.id)
            draftOutcomes[draft.id] = "dismissed"
            return nil
        } catch { return error.localizedDescription }
    }

    func toggle(_ habit: Habit) async {
        let current = habitOverrides[habit.id] ?? habit
        if let updated = try? await api.checkHabit(habit.id, done: !current.doneToday) {
            habitOverrides[habit.id] = updated
        }
    }
}
