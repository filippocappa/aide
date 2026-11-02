import SwiftUI

// The objectives redesign (2026-11-02): a period's proposals come as one plan that starts by itself unless you drop
// something (A), and the week is the page, with each goal's days as dots, today's step inside it and the month as
// a strip under it (B). docs/API.md, "Objectives".

/// A period's plan as one card: every proposal with "Not this", when the rest starts by itself, and Start now.
struct ObjectivePlanCard: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    /// The period's Block with only its proposals in `objectives`.
    let plan: ObjectiveBlock
    /// Loads everything again after an answer.
    let changed: () async -> Void

    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(ObjectiveDates.starts(plan.startsAt), systemImage: plan.startsAt == nil ? "hand.raised" : "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(heading).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plan.objectives) { row($0) }
            }
            Button { Task { await start() } } label: {
                HStack {
                    Spacer()
                    if busy == "start" { ProgressView() } else {
                        Text(plan.objectives.count == 1 ? "Start now" : "Start all \(plan.objectives.count) now")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(busy != nil)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }

    private func row(_ o: Objective) -> some View {
        let agent = chat.agent(o.agent)
        return HStack(alignment: .top, spacing: 10) {
            AgentMark(agent: agent, size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(o.title).multilineTextAlignment(.leading)
                Text([agent.name, ObjectiveWords.planHow(o), ObjectiveWords.due(o)].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { Task { await drop(o) } } label: {
                if busy == o.id { ProgressView().controlSize(.small) } else {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .buttonStyle(.borderless)
            .disabled(busy != nil)
            .accessibilityLabel("Not this one")
        }
    }

    /// "Today's plan", "Your week, 2 – 8 Nov", "November".
    private var heading: String {
        switch plan.period {
        case "week": "Your week, \(ObjectiveDates.span(plan))"
        case "month": "Your month, \(ObjectiveDates.span(plan))"
        default: "Today's plan"
        }
    }

    /// "4 goals from Coach and Professor. Drop what you don't want."
    private var subtitle: String {
        var names: [String] = []
        for o in plan.objectives where !names.contains(chat.agent(o.agent).name) { names.append(chat.agent(o.agent).name) }
        let who = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "the team"
        let n = plan.objectives.count
        let drop = plan.startsAt == nil ? "Start what you want, drop the rest." : "Drop what you don't want."
        return "\(n == 1 ? "1 goal" : "\(n) goals") from \(who). \(drop)"
    }

    private func start() async {
        busy = "start"
        defer { busy = nil }
        do {
            _ = try await env.api.acceptObjectives(period: plan.period, date: plan.start)
            error = nil
        } catch { self.error = error.localizedDescription }
        await changed()
    }

    private func drop(_ o: Objective) async {
        busy = o.id
        defer { busy = nil }
        do {
            _ = try await env.api.updateObjective(o.id, ObjectivePatch(status: "dropped"))
            error = nil
        } catch { self.error = error.localizedDescription }
        await changed()
    }
}

/// A week's goal as a card: whose, the title and how far, its days as dots, today's step (a day objective that
/// serves it), and where its progress comes from. A goal you tick yourself has a real tick box.
struct WeekGoalCard: View {
    let goal: Objective
    let agent: Agent
    /// Today's objectives that serve it.
    let steps: [Objective]
    let tick: (Objective) -> Void
    let open: (Objective) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if goal.canTick { TickBox(objective: goal, tint: agent.tint) { tick(goal) } }
                Button { open(goal) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(agent.tint)
                        Text(goal.title).font(.body.weight(.semibold))
                            .foregroundStyle(goal.done ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Text(ObjectiveWords.tally(goal)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if goal.done {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(agent.tint)
                }
            }
            if let days = goal.days, days.count == 7 {
                DayDots(days: days, tint: agent.tint)
            } else if !goal.canTick, goal.target > 1 {
                ProgressBar(fraction: Double(goal.progress) / Double(max(1, goal.target)), tint: agent.tint)
            }
            ForEach(steps) { step($0) }
            if let source = ObjectiveWords.source(goal) {
                Label(source, systemImage: ObjectiveWords.icon(goal))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .opacity(goal.isLapsed ? 0.6 : 1)
    }

    /// Today's step of it: a tick box (or the ring of one the data ticks) and its title.
    private func step(_ s: Objective) -> some View {
        HStack(spacing: 10) {
            if s.canTick {
                TickBox(objective: s, tint: agent.tint, size: .body) { tick(s) }
            } else {
                ProgressRing(fraction: Double(s.progress) / Double(max(1, s.target)), done: s.done, tint: agent.tint)
                    .frame(width: 18, height: 18)
            }
            Button { open(s) } label: {
                HStack(spacing: 6) {
                    Text("Today").font(.caption.weight(.semibold)).foregroundStyle(agent.tint)
                    Text(s.title).font(.subheadline)
                        .foregroundStyle(s.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(agent.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A month's objective, small: the title, a thin bar and the count (or a tick box for one you tick).
struct MonthGoalRow: View {
    let goal: Objective
    let agent: Agent
    let tick: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if goal.canTick { TickBox(objective: goal, tint: agent.tint, size: .body, action: tick) }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(goal.title).font(.subheadline)
                            .foregroundStyle(goal.done ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text(goal.done ? "Done" : "\(min(goal.progress, goal.target))/\(goal.target)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !goal.canTick {
                        ProgressBar(fraction: goal.done ? 1 : Double(goal.progress) / Double(max(1, goal.target)),
                                    tint: agent.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

/// Monday to Sunday: filled for a day that counted, an empty circle for one that didn't, dashed for days to come.
struct DayDots: View {
    let days: [ObjectiveDay]
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.date) { day in
                let today = day.date == ObjectiveDates.todayString
                VStack(spacing: 4) {
                    dot(day, today: today).frame(width: 22, height: 22)
                    Text(letter(day.date))
                        .font(.caption2.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words(day, today: today))
            }
        }
    }

    @ViewBuilder private func dot(_ day: ObjectiveDay, today: Bool) -> some View {
        if let n = day.count, n > 0 {
            Circle().fill(tint).overlay {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7))
            }
        } else if day.count == nil {
            Circle().strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
        } else if today {
            Circle().strokeBorder(tint, lineWidth: 1.5) // still to do today
        } else {
            Circle().fill(Color.secondary.opacity(0.16))
        }
    }

    private func letter(_ date: String) -> String {
        guard let d = ObjectiveDates.date(date) else { return "" }
        return String(d.formatted(.dateTime.weekday(.narrow)))
    }

    private func words(_ day: ObjectiveDay, today: Bool) -> String {
        let name = ObjectiveDates.date(day.date)?.formatted(.dateTime.weekday(.wide)) ?? day.date
        guard let n = day.count else { return "\(name): to come" }
        return n > 0 ? "\(name): done" : today ? "\(name): not yet" : "\(name): missed"
    }
}

/// A tick box for an objective you tick (a reminder's ticks the reminder).
struct TickBox: View {
    let objective: Objective
    let tint: Color
    var size: Font = .title3
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: objective.done ? "checkmark.circle.fill" : "circle")
                .font(size)
                .foregroundStyle(objective.done ? tint : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(objective.done ? "Mark not done" : "Mark done")
    }
}

struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule().fill(tint).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

extension ObjectiveWords {
    /// "Ticks itself · Apple Health", "You tick it · 3 steps", "Ticks with its reminder": how a proposal would tick.
    static func planHow(_ o: Objective) -> String {
        if o.reminderID != nil { return "Ticks with its reminder" }
        if let m = o.measure {
            let from = m.type == "habit" ? m.origin.map { "your \($0) habit" } : m.origin
            return "Ticks itself · " + (from ?? m.label ?? "the data")
        }
        let steps = o.steps?.count ?? 0
        return steps > 0 ? "You tick it · \(steps) steps" : "You tick it"
    }

    /// "1 of 3", "2 of 4 steps", "Not yet", with "by Wed 12:30" when it's for a time.
    static func tally(_ o: Objective) -> String {
        let steps = o.steps ?? []
        var out: String
        if o.done { out = o.target > 1 ? "\(o.target) of \(o.target) · done" : "Done" }
        else if o.measure != nil || o.target > 1 { out = "\(min(o.progress, o.target)) of \(o.target)" }
        else if !steps.isEmpty { out = "\(steps.filter(\.done).count) of \(steps.count) steps" }
        else { out = "Not yet" }
        if let due = due(o) { out += " · " + due }
        return out
    }

    /// Where its progress comes from, for the card: "From Apple Health", "From your Run habit", nil for one you tick.
    static func source(_ o: Objective) -> String? {
        if o.reminderID != nil { return "Ticks with its reminder" }
        guard let m = o.measure else { return nil }
        guard let origin = m.origin else { return m.label.map { "Ticks itself · \($0)" } }
        return m.type == "habit" ? "From your \(origin) habit" : "From \(origin)"
    }

    /// "by 12:30" today, "by Wed 12:30", "by Wed" for the end of a day; nil without a time.
    static func due(_ o: Objective) -> String? {
        guard let due = o.due, let when = ObjectiveDates.localTime(due) else { return nil }
        let endOfDay = due.hasSuffix("23:59")
        let time = when.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(when) { return endOfDay ? "by tonight" : "by \(time)" }
        let day = when.formatted(.dateTime.weekday(.abbreviated))
        return endOfDay ? "by \(day)" : "by \(day) \(time)"
    }
}

extension ObjectiveDates {
    private static let minute: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// A `due`: local "YYYY-MM-DDTHH:MM".
    static func localTime(_ s: String) -> Date? { minute.date(from: s) }

    static var todayString: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "Starts by itself at 12:00", "Starts by itself Monday at 12:00", or "Waiting for your OK" (an older plan).
    static func starts(_ startsAt: String?) -> String {
        guard let startsAt, let at = Wire.parse(startsAt) else { return "Waiting for your OK" }
        let time = at.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(at) { return "Starts by itself at \(time)" }
        if Calendar.current.isDateInTomorrow(at) { return "Starts by itself tomorrow at \(time)" }
        return "Starts by itself \(at.formatted(.dateTime.weekday(.wide))) at \(time)"
    }
}
