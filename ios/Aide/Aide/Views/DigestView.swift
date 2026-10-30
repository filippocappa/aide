import SwiftUI

/// The latest digest, drawn from its structured sections: when it was written and its note, then a card a section.
/// Reminders and habits can be ticked off here. Unknown section types are skipped.
struct DigestView: View {
    @EnvironmentObject private var model: DigestViewModel
    let digest: Digest?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(overline).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                if let digest {
                    Text(digest.greeting.markdown).font(.title3.weight(.medium)).lineSpacing(4)
                } else if model.isLoading {
                    SkeletonText(paragraphs: 2)
                } else {
                    Text("No \(model.kind.label.lowercased()) briefing yet.").foregroundStyle(.secondary)
                }
            }

            ForEach(digest?.sections ?? []) { section in
                switch section.content {
                case .calendar(let events): group(section.title, padding: 0) { EventRows(events: events) }
                case .reminders(let reminders): group(section.title) { ReminderRows(reminders: reminders) }
                case .habits(let habits): group(section.title) { HabitRows(habits: habits) }
                case .mail(let items): group(section.title, padding: 0) { MailRows(items: items) }
                case .sleep(let night, let usual, let score): group(section.title) { SleepCard(night: night, usualAsleepMin: usual, score: score) }
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

    /// "Evening briefing · written 18:30", "Week briefing · written Sun 20:00".
    private var overline: String {
        let name = "\(model.kind.label) briefing"
        guard let written = digest?.generatedAt.flatMap(Wire.parse) else { return name }
        let time = written.formatted(date: .omitted, time: .shortened)
        let when = Calendar.current.isDateInToday(written) ? time
            : Calendar.current.isDateInYesterday(written) ? "yesterday \(time)"
            : "\(written.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        return "\(name) · written \(when)"
    }

    private func group<Content: View>(_ title: String, padding: CGFloat = 16,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        DetailCard(title, padding: padding) {
            VStack(alignment: .leading, spacing: padding == 0 ? 0 : 14) { content() }
        }
    }
}

/// A day's events as Calendar draws them: the start over the end, a bar in the calendar's colour, the title and
/// place. Days other than today and tomorrow, or several days, each get a small heading.
struct EventRows: View {
    let events: [CalendarEvent]

    var body: some View {
        if events.isEmpty {
            Text("Nothing scheduled.").foregroundStyle(.secondary).padding(16)
        }
        let days = Self.days(events)
        let headed = days.count > 1 || days.first.map { !Self.near($0[0].startDate) } == true
        ForEach(Array(days.enumerated()), id: \.offset) { index, day in
            if headed {
                if index > 0 { Divider() }
                Text(Self.heading(day[0].startDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
            }
            ForEach(Array(day.enumerated()), id: \.element.id) { i, event in
                if i > 0 { RowDivider(leading: 82) }
                row(event)
            }
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

    private static func near(_ day: Date?) -> Bool {
        guard let day else { return true }
        return Calendar.current.isDateInToday(day) || Calendar.current.isDateInTomorrow(day)
    }

    private static func heading(_ day: Date?) -> String {
        guard let day else { return "" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func row(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                if event.allDay {
                    Text("All day").font(.subheadline.weight(.semibold))
                } else {
                    Text(event.startDate?.formatted(date: .omitted, time: .shortened) ?? "")
                        .font(.subheadline.weight(.semibold))
                    if let end = event.endDate {
                        Text(end.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .monospacedDigit()
            .frame(width: 54, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body.weight(.medium))
                if let place = event.location, !place.isEmpty {
                    Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Capsule().fill(event.tint).frame(width: 4) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
                             : due.timeIntervalSinceNow < 6 * 86400 ? ActivityDays.upcoming(due)
                             : due.formatted(date: .abbreviated, time: .shortened))
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

/// The inbox as Mail lists it: the sender's initials, who, when, the subject and the start of the message.
/// Unread ones are bold with a dot. Past five, the rest wait behind "Show all".
private struct MailRows: View {
    let items: [MailItem]
    @State private var expanded = false
    private static let fold = 5

    var body: some View {
        let shown = expanded ? items : Array(items.prefix(Self.fold))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, mail in
            if i > 0 { RowDivider(leading: 64) }
            row(mail)
        }
        if items.count > shown.count {
            RowDivider(leading: 16)
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded = true } } label: {
                Text("Show all \(items.count)")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
        }
    }

    private func row(_ mail: MailItem) -> some View {
        let name = Self.name(mail.from)
        return HStack(alignment: .top, spacing: 12) {
            Text(Self.initials(name))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Theme.chip, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).font(.body.weight(mail.unread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let when = mail.receivedAt.flatMap(Wire.parse) {
                        Text(Self.when(when)).font(.caption).foregroundStyle(.tertiary)
                    }
                    if mail.unread {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8).accessibilityLabel("Unread")
                    }
                }
                Text(mail.subject).font(.subheadline.weight(mail.unread ? .medium : .regular)).lineLimit(1)
                if let preview = mail.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Il Punto <punto@corriere.it>" → "Il Punto"; a bare address keeps its local part.
    static func name(_ from: String) -> String {
        var name = from
        if let open = name.firstIndex(of: "<") { name = String(name[..<open]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        if name.isEmpty { name = from.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        if name.contains("@"), let local = name.split(separator: "@").first { return String(local) }
        return name
    }

    /// Two letters from the first two words that start with one: "Torino F.C." → "TF".
    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").compactMap { $0.first(where: \.isLetter) }.prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// "18:02" today, "Yesterday", else the weekday or the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Last night: time asleep against your usual, bed and wake times, and the stages as one bar.
struct SleepCard: View {
    let night: SleepNight
    let usualAsleepMin: Int?
    /// The sleep score (docs/API.md, "Scores"), when the server has one.
    var score: Int? = nil

    private var stages: [(label: String, minutes: Int, color: Color)] {
        guard let deep = night.deepMin, let core = night.coreMin, let rem = night.remMin else { return [] }
        return [("Deep", deep, .indigo), ("Core", core, .blue), ("REM", rem, .cyan), ("Awake", night.awakeMin ?? 0, .orange)]
            .filter { $0.minutes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Self.duration(night.asleepMin)) asleep").font(.title3.weight(.semibold))
                if let score { ScorePill(text: "Sleep \(score)%", color: ScoreColors.sleep[1]) }
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

/// "Sleep 86%" in a tinted capsule.
struct ScorePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
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
                if let score = recovery.score {
                    ScorePill(text: "\(score)%", color: ScoreColors.recovery(score)[1])
                }
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
