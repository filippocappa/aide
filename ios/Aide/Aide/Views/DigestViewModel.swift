import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case wake, daily, evening, weekly, monthly
        var id: String { rawValue }
        /// The ones to pick from: the wake-up briefing is the morning one ("Morning" is off; older ones still open).
        static let picked: [Kind] = [.wake, .evening, .weekly, .monthly]
        var label: String {
            switch self {
            case .wake: "Wake-up"; case .daily: "Morning"; case .evening: "Evening"; case .weekly: "Week"; case .monthly: "Month"
            }
        }
    }

    @Published var kind: Kind = .wake
    /// The digest sheet is up (from Today's Details, or the Details link under a digest chat).
    @Published var isPresented = false
    /// The kind picked in the sheet.
    @Published private(set) var digest: Digest?
    /// Whichever digest was made last, for the card on Today; nil before the first one.
    @Published private(set) var latest: Digest?
    @Published private(set) var latestLoaded = false
    @Published private(set) var isLoading = false
    /// The digest is being written again (Refresh).
    @Published private(set) var isRefreshing = false
    @Published var refreshError: String?
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
    init(api: APIClient) {
        self.api = api
        // The last one shown, so the Team tab has its note at once; the server's answer replaces it.
        if let data = try? Data(contentsOf: Self.latestFile), let kept = try? JSONDecoder.api.decode(Digest.self, from: data) {
            latest = kept
            latestLoaded = true
        }
    }

    private static let latestFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "latest-digest.json")

    /// Whether this briefing's note has been shown before (it's written in once, the first time).
    func isNew(_ digest: Digest) -> Bool {
        UserDefaults.standard.string(forKey: "digest.seen") != Self.key(digest)
    }

    func markSeen(_ digest: Digest) { UserDefaults.standard.set(Self.key(digest), forKey: "digest.seen") }

    private static func key(_ digest: Digest) -> String { "\(digest.kind) \(digest.generatedAt ?? digest.greeting)" }

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

    /// Writes the picked digest again, so its greeting sees what changed since (an event added after it was made).
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await api.runDigest(kind: kind.rawValue)
            await load()
            if digest == nil { digest = fresh }
            if latest?.kind == fresh.kind { await loadLatest() }
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// The card on Today. An older server doesn't know `latest`: the one for the time of day.
    func loadLatest() async {
        defer { latestLoaded = true }
        do {
            let data = try await api.raw("/v1/digest", query: [URLQueryItem(name: "kind", value: "latest")])
            latest = try JSONDecoder.api.decode(Digest.self, from: data)
            try? data.write(to: Self.latestFile, options: .atomic)
        } catch APIError.server(400, _) {
            latest = try? await api.digest(kind: ChatViewModel.digestKind())
        } catch APIError.server(404, _) {
            latest = nil
            try? FileManager.default.removeItem(at: Self.latestFile)
        } catch {
            // offline: keep what's shown
        }
    }

    /// The sheet, on the latest digest's kind.
    func showLatest() {
        kind = latest.flatMap { Kind(rawValue: $0.kind) } ?? .wake
        isPresented = true
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

    /// A limit habit: one more (1) or one back (-1).
    func count(_ habit: Habit, add: Int) async {
        if let updated = try? await api.countHabit(habit.id, add: add) { habitOverrides[habit.id] = updated }
    }
}
