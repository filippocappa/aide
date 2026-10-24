import SwiftUI
import WidgetKit

/// Today's events still to come and the reminders due, each with a tick box (docs/API.md, "Widgets").
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { TodayView(entry: $0) }
            .configurationDisplayName("Today")
            .description("What's next on your calendar, and your reminders.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let today: Loaded<TodayResponse>?
    var configured = true

    /// Events not over yet at the entry's time.
    var events: [CalendarEvent] {
        (today?.value.events ?? []).filter { ($0.endDate ?? .distantFuture) > date }
            .sorted { ($0.allDay ? 0 : 1, $0.startDate ?? .distantPast) < ($1.allDay ? 0 : 1, $1.startDate ?? .distantPast) }
    }

    /// Timed events first in a glance: an all-day one is the day's backdrop, not what's next.
    var next: CalendarEvent? { events.first { !$0.allDay } ?? events.first }

    var reminders: [Reminder] {
        (today?.value.reminders ?? []).filter { !$0.completed && !$0.deleted }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), today: nil) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        provide({ completion($0.entries[0]) }) { await timeline() }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        provide(completion) { await timeline() }
    }

    /// An entry now and one as each event ends, so the widget moves on by itself; read again in 30 minutes.
    @MainActor private func timeline() async -> Timeline<TodayEntry> {
        let now = Date()
        guard WidgetAPI.isConfigured else {
            return Timeline(entries: [TodayEntry(date: now, today: nil, configured: false)], policy: .after(now + 3600))
        }
        let today = await WidgetCache.load(TodayResponse.self, "/v1/today")
        let ends = (today?.value.events ?? []).compactMap { $0.allDay ? nil : $0.endDate }
            .filter { $0 > now && $0 < now + 6 * 3600 }.sorted().prefix(8)
        let entries = [TodayEntry(date: now, today: today)] + ends.map { TodayEntry(date: $0, today: today) }
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
        return Timeline(entries: entries, policy: .after(min(now + 30 * 60, midnight)))
    }
}

struct TodayView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.widgetBackground().widgetURL(URL(string: "aide://today"))
    }

    @ViewBuilder private var content: some View {
        if !entry.configured {
            WidgetNote(text: WidgetNote.setUp)
        } else if entry.today == nil {
            WidgetNote(text: "Can't reach Aide. Is Tailscale on?")
        } else {
            switch family {
            case .accessoryInline: inline
            case .accessoryRectangular: rectangular
            case .systemSmall: small
            default: list(events: family == .systemLarge ? 4 : 2, reminders: family == .systemLarge ? 6 : 3)
            }
        }
    }

    @ViewBuilder private var inline: some View {
        if let next = entry.next {
            Text(next.allDay ? next.title : "\(time(next)) \(next.title)")
        } else {
            Text(entry.reminders.isEmpty ? "Nothing else today" : "\(entry.reminders.count) reminders")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = entry.next {
                Text(next.allDay ? "Today" : time(next)).font(.caption.weight(.semibold))
                Text(next.title).font(.headline).lineLimit(1)
            } else {
                Text("Nothing else today").font(.headline)
            }
            if !entry.reminders.isEmpty {
                Label("\(entry.reminders.count) reminder\(entry.reminders.count == 1 ? "" : "s")", systemImage: "checklist")
                    .font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: entry.date.formatted(.dateTime.weekday(.abbreviated).day()), fresh: entry.today?.fresh ?? true)
            if let next = entry.next {
                Text(next.allDay ? "All day" : time(next))
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.tint(for: next.calendar ?? next.title))
                Text(next.title).font(.headline).lineLimit(3)
                if let place = next.location, !place.isEmpty {
                    Text(place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Nothing else on the calendar").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let first = entry.reminders.first {
                reminderRow(first)
            }
        }
    }

    private func list(events: Int, reminders: Int) -> some View {
        let shown = Array(entry.events.prefix(events))
        let todo = Array(entry.reminders.prefix(reminders + max(0, events - shown.count)))
        return VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: entry.date.formatted(.dateTime.weekday(.wide).day().month()), fresh: entry.today?.fresh ?? true)
            if shown.isEmpty && todo.isEmpty {
                WidgetNote(text: "Nothing else today.", symbol: "sun.max")
            }
            ForEach(shown) { eventRow($0) }
            if !shown.isEmpty && !todo.isEmpty { Divider() }
            ForEach(todo) { reminderRow($0) }
            Spacer(minLength: 0)
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.tint(for: event.calendar ?? event.title)).frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(event.allDay ? "All day" : event.timeText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !event.allDay, let start = event.startDate, start <= entry.date {
                Text("Now").font(.caption2.weight(.bold)).foregroundStyle(Theme.tint(for: event.calendar ?? event.title))
            }
        }
        .frame(height: 30)
    }

    private func reminderRow(_ reminder: Reminder) -> some View {
        HStack(spacing: 8) {
            Button(intent: CompleteReminderIntent(id: reminder.id)) {
                Image(systemName: "circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(reminder.title)")
            Text(reminder.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
            if let due = reminder.dueDate {
                Text(due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(due < entry.date ? .red : .secondary)
            }
        }
    }

    private func time(_ event: CalendarEvent) -> String {
        event.startDate?.formatted(date: .omitted, time: .shortened) ?? ""
    }
}
