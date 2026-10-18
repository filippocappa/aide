import SwiftUI

/// The latest digest, drawn from its structured sections. Unknown section types are skipped.
struct DigestView: View {
    @EnvironmentObject private var model: DigestViewModel
    let digest: Digest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Period", selection: $model.kind) {
                ForEach(DigestViewModel.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.kind) { _, _ in Task { await model.load() } }

            if let digest {
                Text(digest.greeting.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            } else {
                Text("No \(model.kind.label.lowercased()) digest yet.").foregroundStyle(.secondary)
            }

            ForEach(digest?.sections ?? []) { section in
                switch section.content {
                case .calendar(let events): card(section.title) { CalendarTiles(events: events) }
                case .mail(let items): card(section.title) { MailCards(items: items) }
                case .reminders(let reminders): card(section.title) { ReminderRows(reminders: reminders) }
                case .habits(let habits): card(section.title) { HabitRows(habits: habits) }
                case .text(let text): card(section.title) { RichText(text: text) }
                case .unknown: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CalendarTiles: View {
    let events: [CalendarEvent]

    var body: some View {
        if events.isEmpty {
            Text("Nothing scheduled.").foregroundStyle(.secondary)
        }
        ForEach(events) { event in
            let tint = Theme.tint(for: event.calendar ?? event.title)
            HStack(spacing: 12) {
                Capsule().fill(tint).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.body.weight(.medium))
                    Text(event.timeText).font(.caption.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
                    if let place = event.location, !place.isEmpty {
                        Label(place, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let calendar = event.calendar {
                    Text(calendar).font(.caption2).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .fixedSize(horizontal: false, vertical: true)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct MailCards: View {
    let items: [MailItem]

    var body: some View {
        ForEach(items) { mail in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if mail.unread { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                    Text(mail.from).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(mail.subject).font(.callout).lineLimit(1)
                if let preview = mail.preview, !preview.isEmpty {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct ReminderRows: View {
    let reminders: [Reminder]

    var body: some View {
        ForEach(reminders) { r in
            HStack(spacing: 10) {
                Image(systemName: r.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                Text(r.title).strikethrough(r.completed)
                Spacer(minLength: 0)
                if let due = r.dueDate {
                    Text(due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(due < Date() && !r.completed ? Color.red : Color.secondary)
                }
            }
        }
    }
}

private struct HabitRows: View {
    @EnvironmentObject private var model: DigestViewModel
    let habits: [Habit]

    var body: some View {
        ForEach(habits) { original in
            let habit = model.habitOverrides[original.id] ?? original
            HStack(spacing: 12) {
                Button {
                    Task { await model.toggle(habit) }
                } label: {
                    Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(habit.name)
                    Text(habit.cadenceText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if habit.streak > 0 {
                    Label("\(habit.streak)", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
            }
        }
    }
}
