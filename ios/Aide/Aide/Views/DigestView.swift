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
            } else if model.isLoading {
                SkeletonText(paragraphs: 2)
            } else {
                Text("No \(model.kind.label.lowercased()) digest yet.").foregroundStyle(.secondary)
            }

            ForEach(digest?.sections ?? []) { section in
                switch section.content {
                case .calendar(let events): group(section.title) { EventRows(events: events) }
                case .reminders(let reminders): group(section.title) { ReminderRows(reminders: reminders) }
                case .habits(let habits): group(section.title) { HabitRows(habits: habits) }
                case .mail(let items): group(section.title) { MailRows(items: items) }
                case .sleep(let night, let usual): group(section.title) { SleepCard(night: night, usualAsleepMin: usual) }
                case .recovery(let recovery): group(section.title) { RecoveryRow(recovery: recovery) }
                case .objectives(let objectives, let period):
                    group(section.title) { DigestObjectiveRows(objectives: objectives, period: period) }
                case .replies(let drafts): group(section.title) { DigestDraftRows(drafts: drafts) }
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
struct EventRows: View {
    let events: [CalendarEvent]

    var body: some View {
        if events.isEmpty {
            Text("Nothing scheduled.").foregroundStyle(.secondary)
        }
        let days = Self.days(events)
        if days.count > 1 {
            // Several days: each under its own heading, the rows with just the time.
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                Text(Self.heading(day[0].startDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, index == 0 ? 0 : 6)
                ForEach(day) { row($0, weekday: false) }
            }
        } else {
            ForEach(events) { row($0, weekday: true) }
        }
    }

    /// Runs of events on the same day, in order.
    private static func days(_ events: [CalendarEvent]) -> [[CalendarEvent]] {
        var days: [[CalendarEvent]] = []
        for event in events {
            if let last = days.last?.last, Calendar.current.isDate(last.startDate ?? .distantPast,
                                                                    inSameDayAs: event.startDate ?? .distantPast) {
                days[days.count - 1].append(event)
            } else {
                days.append([event])
            }
        }
        return days
    }

    private static func heading(_ day: Date?) -> String {
        guard let day else { return "" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func row(_ event: CalendarEvent, weekday: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if weekday, let day = event.startDate, !Calendar.current.isDateInToday(day) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold))
                }
                Text(event.allDay ? "All day" : event.startDate?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(event.tint)
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
            if habit.isLimit {
                HStack(spacing: 12) {
                    Text(habit.name)
                    Spacer(minLength: 0)
                    LimitCounter(habit: habit) { n in Task { await model.count(habit, add: n) } }
                }
            } else {
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
}

/// The team's objectives, with the specialist's name; tick the ones you tick, and OK the proposals in one go.
private struct DigestObjectiveRows: View {
    @EnvironmentObject private var model: DigestViewModel
    @EnvironmentObject private var chat: ChatViewModel
    let objectives: [Objective]
    let period: String

    var body: some View {
        let shown = objectives.map { model.objectiveOverrides[$0.id] ?? $0 }
        ForEach(shown) { o in
            let agent = chat.agent(o.agent)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(agent.tint)
                ObjectiveRow(objective: o, tint: agent.tint) { Task { await model.tick(o) } }
            }
        }
        let proposed = shown.filter(\.isProposed)
        if let first = proposed.first {
            Button { Task { await model.accept(proposed, period: period, date: first.start) } } label: {
                Text(proposed.count == 1 ? "Accept it" : "Accept all \(proposed.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
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

/// Last night: time asleep against your usual, bed and wake times, and the stages as one bar.
struct SleepCard: View {
    let night: SleepNight
    let usualAsleepMin: Int?

    private var stages: [(label: String, minutes: Int, color: Color)] {
        guard let deep = night.deepMin, let core = night.coreMin, let rem = night.remMin else { return [] }
        return [("Deep", deep, .indigo), ("Core", core, .blue), ("REM", rem, .cyan), ("Awake", night.awakeMin ?? 0, .orange)]
            .filter { $0.minutes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Self.duration(night.asleepMin)) asleep").font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if let span = timeSpan { Text(span).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let usual = usualAsleepMin { Text(Self.compare(night.asleepMin, usual)).font(.subheadline).foregroundStyle(.secondary) }
            if !stages.isEmpty {
                GeometryReader { geo in
                    let total = CGFloat(stages.reduce(0) { $0 + $1.minutes })
                    HStack(spacing: 2) {
                        ForEach(stages, id: \.label) { stage in
                            stage.color.frame(width: max(2, (geo.size.width - CGFloat(stages.count - 1) * 2) * CGFloat(stage.minutes) / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    ForEach(stages, id: \.label) { stage in
                        HStack(spacing: 5) {
                            Circle().fill(stage.color).frame(width: 7, height: 7)
                            Text("\(stage.label) \(Self.duration(stage.minutes))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "00:12 – 07:41"
    private var timeSpan: String? {
        guard let bed = night.bedtimeDate, let wake = night.wakeDate else { return nil }
        return "\(bed.formatted(date: .omitted, time: .shortened)) – \(wake.formatted(date: .omitted, time: .shortened))"
    }

    /// "6h 52m", or "45m" under an hour.
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// Within 15 minutes counts as usual.
    static func compare(_ minutes: Int, _ usual: Int) -> String {
        let diff = minutes - usual
        if abs(diff) < 15 { return "About your usual" }
        return "\(duration(abs(diff))) \(diff < 0 ? "under" : "over") your usual \(duration(usual))"
    }
}

/// How rested the numbers say you are, compared with your own usual. Not medical advice.
struct RecoveryRow: View {
    let recovery: Recovery

    private var look: (label: String, color: Color) {
        switch recovery.level {
        case "good": ("Recovered", .green)
        case "low": ("Take it easier", .orange)
        default: ("Normal", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(look.color).frame(width: 9, height: 9)
                Text(look.label).font(.body.weight(.semibold))
            }
            Text(recovery.summary).font(.subheadline)
            HStack(spacing: 16) {
                if let hrv = recovery.hrvMs {
                    Text("HRV \(Int(hrv.rounded())) ms" + (recovery.hrvUsualMs.map { " · usual \(Int($0.rounded()))" } ?? ""))
                }
                if let rhr = recovery.restingHr {
                    Text("Resting \(rhr) bpm" + (recovery.restingHrUsual.map { " · usual \($0)" } ?? ""))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
