import SwiftUI

/// The latest digest, drawn from its structured sections: Pebble's greeting, then short plain lists
/// under small headings. Reminders and habits can be ticked off here. Unknown section types are skipped.
struct DigestView: View {
    @EnvironmentObject private var model: DigestViewModel
    let digest: Digest?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let digest {
                Text(digest.greeting.markdown).font(.title3.weight(.medium)).lineSpacing(4)
            } else {
                Text("No \(model.kind.label.lowercased()) digest yet.").foregroundStyle(.secondary)
            }

            ForEach(digest?.sections ?? []) { section in
                switch section.content {
                case .calendar(let events): group(section.title) { EventRows(events: events) }
                case .reminders(let reminders): group(section.title) { ReminderRows(reminders: reminders) }
                case .habits(let habits): group(section.title) { HabitRows(habits: habits) }
                case .mail(let items): group(section.title) { MailRows(items: items) }
                case .text, .unknown: EmptyView() // the greeting already says it
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Time on the left, title on the right; the weekday too when it isn't today.
private struct EventRows: View {
    let events: [CalendarEvent]

    var body: some View {
        if events.isEmpty {
            Text("Nothing scheduled.").foregroundStyle(.secondary)
        }
        ForEach(events) { event in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    if let day = event.startDate, !Calendar.current.isDateInToday(day) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold))
                    }
                    Text(event.allDay ? "All day" : event.startDate?.formatted(date: .omitted, time: .shortened) ?? "")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.tint(for: event.calendar ?? event.title))
                .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                    if let place = event.location, !place.isEmpty {
                        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Tap the circle to tick it off: done on the phone (Apple Reminders), then synced to the server.
struct ReminderRows: View {
    @EnvironmentObject private var model: DigestViewModel
    let reminders: [Reminder]

    var body: some View {
        ForEach(reminders) { r in
            let done = model.reminderOverrides[r.id] ?? r.completed
            Button {
                Task { await model.setCompleted(r, !done) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                    Text(r.title)
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if let due = r.dueDate {
                        let late = (r.overdue || due < Date()) && !done
                        Text(late && !Calendar.current.isDateInToday(due) ? "Overdue"
                             : due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened))
                            .font(.caption.weight(late ? .semibold : .regular))
                            .foregroundStyle(late ? Color.red : Color.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Mark \(r.title) not done" : "Mark \(r.title) done")
        }
    }
}

private struct HabitRows: View {
    @EnvironmentObject private var model: DigestViewModel
    let habits: [Habit]

    var body: some View {
        ForEach(habits) { original in
            let habit = model.habitOverrides[original.id] ?? original
            Button {
                Task { await model.toggle(habit) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                    Text(habit.name)
                    Spacer(minLength: 0)
                    if habit.streak > 0 {
                        Label("\(habit.streak)", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// One line each: who, and what about. Unread ones get a dot.
private struct MailRows: View {
    let items: [MailItem]

    var body: some View {
        ForEach(items) { mail in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(mail.unread ? Theme.accent : .clear).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mail.from).font(.subheadline.weight(mail.unread ? .semibold : .regular)).lineLimit(1)
                    Text(mail.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
