import Foundation

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let api: APIClient
    private let sync: ReminderSyncService

    init(api: APIClient, sync: ReminderSyncService) {
        self.api = api
        self.sync = sync
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.today(date: isToday ? nil : date)
            // All-day first, then by start time.
            events = response.events.sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                return ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
            }
            reminders = response.reminders.filter { !$0.deleted }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func shiftDay(by days: Int) async {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        await load()
    }

    func goToToday() async {
        date = Calendar.current.startOfDay(for: Date())
        await load()
    }

    /// Pull-to-refresh: reminders first, so the list reflects what the phone just pushed.
    func refresh() async {
        await sync.sync()
        await load()
    }

    func toggle(_ reminder: Reminder) async {
        if let i = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[i].completed.toggle()
        }
        await sync.setCompleted(reminder, !reminder.completed)
        await load()
    }
}
