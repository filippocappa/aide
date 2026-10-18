import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var today: TodayViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                if let error = today.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section("Events") {
                    if today.events.isEmpty {
                        Text(today.isLoading ? "Loading…" : "Nothing on the calendar.").foregroundStyle(.secondary)
                    }
                    ForEach(today.events) { EventRow(event: $0) }
                }
                Section("Reminders") {
                    if today.reminders.isEmpty {
                        Text(today.isLoading ? "Loading…" : "Nothing due.").foregroundStyle(.secondary)
                    }
                    ForEach(today.reminders) { ReminderRow(reminder: $0) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(today.isToday ? "Today" : today.date.formatted(.dateTime.weekday(.wide).day().month()))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Previous day", systemImage: "chevron.left") { Task { await today.shiftDay(by: -1) } }
                    if !today.isToday {
                        Button("Today") { Task { await today.goToToday() } }
                    }
                    Button("Next day", systemImage: "chevron.right") { Task { await today.shiftDay(by: 1) } }
                }
            }
            .refreshable { await today.refresh() }
            .task { if settings.isConfigured { await today.load() } }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.title).font(.body.weight(.medium))
                if event.recurring {
                    Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(event.timeText).font(.subheadline).foregroundStyle(.secondary)
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ReminderRow: View {
    @EnvironmentObject private var today: TodayViewModel
    let reminder: Reminder

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await today.toggle(reminder) }
            } label: {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.appleId == nil ? Color.secondary.opacity(0.4) : Theme.accent)
            }
            .buttonStyle(.plain)
            // Only the phone can write to Apple Reminders, so a reminder that hasn't reached it can't be ticked here.
            .disabled(reminder.appleId == nil)
            .accessibilityLabel(reminder.completed ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .strikethrough(reminder.completed)
                    .foregroundStyle(reminder.completed ? .secondary : .primary)
                if let due = reminder.dueDate {
                    Text(due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(due < Date() && !reminder.completed ? Color.red : Color.secondary)
                }
            }
        }
    }
}
