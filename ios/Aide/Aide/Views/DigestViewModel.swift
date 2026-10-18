import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case daily, evening, weekly, monthly
        var id: String { rawValue }
        var label: String { switch self { case .daily: "Morning"; case .evening: "Evening"; case .weekly: "Week"; case .monthly: "Month" } }
    }

    @Published var kind: Kind = .daily
    @Published private(set) var digest: Digest?
    @Published private(set) var isLoading = false
    /// True once any digest has loaded, so the picker stays when one period has none yet.
    @Published private(set) var hasDigests = false
    /// Habits ticked here, newer than the digest's snapshot.
    @Published private(set) var habitOverrides: [Int: Habit] = [:]

    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            digest = try await api.digest(kind: kind.rawValue)
            hasDigests = true
            habitOverrides = [:]
        } catch {
            digest = nil // 404 until the first digest exists; the empty chat falls back to suggestions
        }
    }

    func toggle(_ habit: Habit) async {
        let current = habitOverrides[habit.id] ?? habit
        if let updated = try? await api.checkHabit(habit.id, done: !current.doneToday) {
            habitOverrides[habit.id] = updated
        }
    }
}
