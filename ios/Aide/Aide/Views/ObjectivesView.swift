import SwiftUI

/// One objective: a tick box when you tick it (or its reminder), a ring when the data ticks it; how it's ticked,
/// how far along, and why.
struct ObjectiveRow: View {
    let objective: Objective
    let tint: Color
    /// Ticks or unticks it; nil where it can't be changed.
    var tick: (() -> Void)?
    /// Opens its page (steps, how it's ticked); nil: the row does nothing.
    var open: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark.padding(.top, 1)
            Button { open?() } label: { text }
                .buttonStyle(.plain)
                .disabled(open == nil)
        }
        .padding(.vertical, 2)
        .opacity(objective.isLapsed ? 0.6 : 1)
    }

    private var text: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(objective.title)
                        .foregroundStyle(objective.done || objective.isLapsed ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if objective.isProposed {
                        Text("Proposed").font(.caption2.weight(.semibold)).foregroundStyle(tint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(tint.opacity(0.14), in: Capsule())
                    } else if objective.isLapsed {
                        Text("Not taken").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let how = ObjectiveWords.how(objective) {
                    Label { Text(how) } icon: { Image(systemName: ObjectiveWords.icon(objective)) }
                        .labelStyle(.compact)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(objective.isManual ? Color.secondary : tint)
                }
                if let why = objective.why, !why.isEmpty {
                    Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if open != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A tick box for one you tick (a reminder's ticks the reminder); a ring, not a button, for one the data ticks.
    @ViewBuilder private var mark: some View {
        if objective.canTick || objective.isManual {
            Button { tick?() } label: {
                Image(systemName: objective.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(objective.done ? tint : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(tick == nil || !objective.canTick)
            .accessibilityLabel(objective.done ? "Mark not done" : "Mark done")
        } else {
            ProgressRing(fraction: objective.done ? 1 : Double(objective.progress) / Double(max(1, objective.target)),
                         done: objective.done, tint: tint)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Ticks itself")
        }
    }
}

/// How an objective is ticked, in words.
enum ObjectiveWords {
    /// "Ticks itself · 2 of 5 nights with 7h of sleep or more", "Ticks with its reminder", "1 of 3 steps".
    static func how(_ o: Objective) -> String? {
        let steps = o.steps ?? []
        if o.reminderID != nil { return "Ticks with its reminder" }
        if let label = o.measure?.label {
            let count = o.target > 1 ? "\(min(o.progress, o.target)) of \(o.target) \(label)" : label
            return "Ticks itself · " + count
        }
        if !steps.isEmpty { return "\(steps.filter(\.done).count) of \(steps.count) steps" }
        return nil
    }

    static func icon(_ o: Objective) -> String {
        if o.reminderID != nil { return "bell.fill" }
        if o.measure != nil { return "arrow.triangle.2.circlepath" }
        return "checklist"
    }

    /// The longer story, for its page.
    static func explain(_ o: Objective) -> String {
        if o.reminderID != nil {
            return "It's done when its reminder is. Ticking it here completes the reminder in Apple Reminders too."
        }
        if let m = o.measure {
            return "It ticks itself from \(m.source), so there's nothing to tick by hand: \(min(o.progress, o.target)) of \(o.target) so far."
        }
        if !(o.steps ?? []).isEmpty { return "You tick it, step by step: it's done when every step is." }
        return "You tick it yourself, when it's done."
    }
}

private extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.font(.caption2)
            configuration.title
        }
    }
}

/// An objective's page: how it's ticked, its steps (tick, add, reorder, delete), the title, why, and Drop.
struct ObjectiveDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var objective: Objective
    let agent: Agent
    let tick: (Objective) async -> Objective?
    let update: (Objective, ObjectivePatch) async -> Objective?
    @State private var title = ""
    @State private var newStep = ""
    @State private var busy = false
    @FocusState private var adding: Bool

    private var steps: [ObjectiveStep] { objective.steps ?? [] }
    /// Steps need a server that has them (nil from an older one).
    private var hasSteps: Bool { objective.steps != nil }
    private var editable: Bool { !objective.isLapsed }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1...4)
                        .disabled(!editable)
                        .onSubmit { Task { await rename() } }
                        .submitLabel(.done)
                    if let why = objective.why, !why.isEmpty {
                        Text(why).font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: {
                    Label { Text(agent.name) } icon: { AgentMark(agent: agent, size: 18) }
                }
                .listRowBackground(Theme.row)

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: ObjectiveWords.icon(objective))
                            .foregroundStyle(agent.tint)
                            .frame(width: 22)
                        Text(ObjectiveWords.explain(objective)).font(.subheadline)
                    }
                    if objective.reminderID == nil && (!objective.isManual || !steps.isEmpty) {
                        ProgressView(value: Double(min(objective.progress, objective.target)),
                                     total: Double(max(1, objective.target)))
                            .tint(agent.tint)
                    }
                    if objective.canTick {
                        Button {
                            Task { busy = true; if let o = await tick(objective) { objective = o }; busy = false }
                        } label: {
                            Label(objective.done ? "Mark not done" : "Mark done",
                                  systemImage: objective.done ? "arrow.uturn.backward" : "checkmark.circle")
                        }
                        .disabled(busy)
                    }
                } header: {
                    Text(objective.done ? "Done" : "How it's ticked")
                }
                .listRowBackground(Theme.row)

                if hasSteps {
                    Section {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            Button { Task { await toggle(i) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(step.done ? agent.tint : .secondary)
                                    Text(step.text)
                                        .foregroundStyle(step.done ? .secondary : .primary)
                                        .strikethrough(step.done, color: .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!editable || busy)
                        }
                        .onDelete { at in Task { await save(steps.enumerated().filter { !at.contains($0.offset) }.map(\.element)) } }
                        .onMove { from, to in var s = steps; s.move(fromOffsets: from, toOffset: to); Task { await save(s) } }
                        .deleteDisabled(!editable)
                        if editable && steps.count < 10 {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(agent.tint)
                                TextField("Add a step", text: $newStep)
                                    .focused($adding)
                                    .submitLabel(.done)
                                    .onSubmit { Task { await addStep() } }
                            }
                        }
                    } header: {
                        Text("Steps")
                    } footer: {
                        Text(objective.isManual
                             ? "Break it into steps. It's done when every step is."
                             : "A checklist for you. The objective still ticks itself from the data.")
                    }
                    .listRowBackground(Theme.row)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(ObjectiveDates.this(objective.period).prefix(1).uppercased() + ObjectiveDates.this(objective.period).dropFirst())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await rename(); dismiss() } }
                }
                if hasSteps && steps.count > 1 && editable {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .onAppear { title = objective.title }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.grouped)
    }

    private func rename() async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editable, !t.isEmpty, t != objective.title else { return }
        if let o = await update(objective, ObjectivePatch(title: t)) { objective = o }
    }

    private func toggle(_ i: Int) async {
        var s = steps
        s[i].done.toggle()
        await save(s)
    }

    private func addStep() async {
        let t = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        newStep = ""
        await save(steps + [ObjectiveStep(text: t, done: false)])
        adding = true
    }

    private func save(_ s: [ObjectiveStep]) async {
        busy = true
        defer { busy = false }
        objective.steps = s // shown at once; the server's answer follows
        if let o = await update(objective, ObjectivePatch(steps: s)) { objective = o }
    }
}

/// How far along a measured objective is; a tick once it's done.
private struct ProgressRing: View {
    let fraction: Double
    let done: Bool
    let tint: Color

    var body: some View {
        ZStack {
            // dashed: it isn't a box to tick
            Circle().stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [2.6, 2.6]))
            Circle().trim(from: 0, to: min(1, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            }
        }
        .padding(1.5)
    }
}

/// Your own objective: whose, and what. It starts accepted, ticked by hand.
struct NewObjectiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var period: String
    let agents: [Agent]
    let save: (NewObjective) async -> Void
    @State private var agent = ""
    @State private var title = ""
    @State private var steps: [String] = []
    @State private var step = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Run 3 times", text: $title, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Label(s, systemImage: "circle").foregroundStyle(.primary)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    if steps.count < 10 {
                        TextField("Add a step", text: $step)
                            .submitLabel(.next)
                            .onSubmit {
                                let s = step.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !s.isEmpty { steps.append(s) }
                                step = ""
                            }
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Optional. With steps, it's done when every step is.")
                }
                Section {
                    Picker("For", selection: $period) {
                        Text("Today").tag("day"); Text("This week").tag("week"); Text("This month").tag("month")
                    }
                    Picker("Whose", selection: $agent) {
                        ForEach(agents) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text("You tick it yourself. To have it tick itself from your habits, food or sleep, ask the specialist in chat.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("New objective")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            let last = step.trimmingCharacters(in: .whitespacesAndNewlines)
                            await save(NewObjective(agent: agent, period: period,
                                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    steps: steps + (last.isEmpty ? [] : [last])))
                            dismiss()
                        }
                    }
                    .disabled(saving || agent.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if agent.isEmpty { agent = agents.first?.id ?? "" } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.grouped)
    }
}

/// The words for a period and its dates.
enum ObjectiveDates {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }

    /// "Thursday 22 October", "19 – 25 October", "October 2026".
    static func span(_ block: ObjectiveBlock) -> String {
        guard let start = date(block.start), let end = date(block.end) else { return "" }
        switch block.period {
        case "day": return start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case "week": return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        default: return start.formatted(.dateTime.month(.wide).year())
        }
    }

    static func this(_ period: String) -> String {
        period == "week" ? "this week" : period == "month" ? "this month" : "today"
    }

    static func when(_ period: String) -> String {
        period == "week" ? "with the weekly digest" : period == "month" ? "on the 1st" : "every morning"
    }
}
