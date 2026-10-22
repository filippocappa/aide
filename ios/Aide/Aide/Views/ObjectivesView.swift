import SwiftUI

/// The Objectives tab: what each specialist sets out for the day, the week and the month (docs/API.md,
/// "Objectives"). The team proposes them each morning, week and month; you accept, drop or add your own. Most tick
/// themselves from the data behind them (habits, practice exams, food, sleep, steps, a reminder); the rest you tick here.
struct ObjectivesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    /// Proposals waiting for your OK, for the tab's badge.
    @Binding var waiting: Int
    @State private var period = "day"
    @State private var overview: ObjectivesOverview?
    @State private var error: String?
    @State private var planning = false
    @State private var adding = false

    private static let periods = [("day", "Today"), ("week", "Week"), ("month", "Month")]

    var body: some View {
        NavigationStack { list }
            .onChange(of: overview?.waiting) { _, n in if let n { waiting = n } }
    }

    private var list: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let block { Text(ObjectiveDates.span(block)).font(.subheadline) }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            if let block {
                if !block.proposed.isEmpty {
                    Section {
                        Button { Task { await accept(block, ids: nil) } } label: {
                            Label(block.proposed.count == 1 ? "Accept the proposal" : "Accept all \(block.proposed.count)",
                                  systemImage: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    } footer: {
                        Text("Proposed by your team. Swipe one to accept or drop it on its own.")
                    }
                }
                ForEach(owners(block), id: \.self) { id in
                    let agent = chat.agent(id)
                    Section {
                        ForEach(block.objectives.filter { $0.agent == id }) { o in
                            ObjectiveRow(objective: o, tint: agent.tint) { Task { await tick(o) } }
                                .swipeActions(edge: .leading) {
                                    if o.isProposed {
                                        Button("Accept") { Task { await accept(block, ids: [o.id]) } }.tint(.green)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if !o.isLapsed {
                                        Button("Drop", role: .destructive) { Task { await drop(o) } }
                                    }
                                }
                                .listRowBackground(Theme.row)
                        }
                    } header: {
                        Label { Text(agent.name) } icon: { AgentMark(agent: agent, size: 18) }
                    }
                }
                if block.objectives.isEmpty {
                    Section {
                        Text(block.planned ? "Nothing set for \(ObjectiveDates.this(period)). Add one, or ask the team for a plan."
                             : "Not planned yet. The team proposes \(ObjectiveDates.when(period)), or now:")
                            .foregroundStyle(.secondary)
                        proposeButton
                    }
                }
            } else if !planning && error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Objectives")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add an objective", systemImage: "plus") { adding = true }
                    Button("Propose new ones", systemImage: "sparkles") { Task { await plan() } }
                        .disabled(planning)
                } label: {
                    if planning { ProgressView() } else { Image(systemName: "plus") }
                }
                .accessibilityLabel("Add or propose")
            }
        }
        .sheet(isPresented: $adding) {
            NewObjectiveSheet(period: period, agents: chat.agents.filter { !$0.orchestrator }) { new in
                await add(new)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var block: ObjectiveBlock? { overview?[period] }

    private var proposeButton: some View {
        Button { Task { await plan() } } label: {
            HStack {
                Label("Propose \(ObjectiveDates.this(period))'s objectives", systemImage: "sparkles")
                if planning { Spacer(); ProgressView() }
            }
        }
        .disabled(planning)
    }

    /// Agents with objectives in this block, in the team's order.
    private func owners(_ block: ObjectiveBlock) -> [String] {
        let ids = Set(block.objectives.map(\.agent))
        return chat.agents.map(\.id).filter(ids.contains) + ids.subtracting(chat.agents.map(\.id)).sorted()
    }

    private func load() async {
        do { overview = try await env.api.objectives(); error = nil } catch { self.error = describe(error) }
    }

    private func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't have objectives yet. Update the server first." }
        return error.localizedDescription
    }

    private func replace(_ o: Objective) {
        guard var block = overview?[o.period] else { return }
        if let i = block.objectives.firstIndex(where: { $0.id == o.id }) {
            if o.status == "dropped" { block.objectives.remove(at: i) } else { block.objectives[i] = o }
        } else {
            block.objectives.append(o)
        }
        overview?[o.period] = block
    }

    private func tick(_ o: Objective) async {
        do { replace(try await env.api.updateObjective(o.id, ObjectivePatch(done: !o.done))); error = nil }
        catch { self.error = describe(error) }
    }

    private func drop(_ o: Objective) async {
        do { replace(try await env.api.updateObjective(o.id, ObjectivePatch(status: "dropped"))); error = nil }
        catch { self.error = describe(error) }
    }

    private func accept(_ block: ObjectiveBlock, ids: [String]?) async {
        do { overview?[block.period] = try await env.api.acceptObjectives(period: block.period, date: block.start, ids: ids); error = nil }
        catch { self.error = describe(error) }
    }

    private func plan() async {
        guard let block else { return }
        planning = true
        defer { planning = false }
        do { overview?[block.period] = try await env.api.planObjectives(period: block.period, date: block.start); error = nil }
        catch { self.error = describe(error) }
    }

    private func add(_ new: NewObjective) async {
        do { replace(try await env.api.addObjective(new)); error = nil } catch { self.error = describe(error) }
    }
}

/// One objective: a tick box when you tick it, a ring when the data does; how far along, and why.
struct ObjectiveRow: View {
    let objective: Objective
    let tint: Color
    /// Ticks or unticks one without a measure; nil where it can't be changed.
    var tick: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark.padding(.top, 1)
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
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
        .opacity(objective.isLapsed ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        if objective.isManual {
            Button { tick?() } label: {
                Image(systemName: objective.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(objective.done ? tint : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(tick == nil || objective.isLapsed)
            .accessibilityLabel(objective.done ? "Mark not done" : "Mark done")
        } else {
            ProgressRing(fraction: objective.done ? 1 : Double(objective.progress) / Double(max(1, objective.target)),
                         done: objective.done, tint: tint)
                .frame(width: 22, height: 22)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let label = objective.measure?.label {
            parts.append(objective.target > 1 ? "\(min(objective.progress, objective.target)) of \(objective.target) \(label)" : label.prefix(1).uppercased() + label.dropFirst())
        }
        if let why = objective.why, !why.isEmpty { parts.append(why) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// How far along a measured objective is; a tick once it's done.
private struct ProgressRing: View {
    let fraction: Double
    let done: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
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
private struct NewObjectiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var period: String
    let agents: [Agent]
    let save: (NewObjective) async -> Void
    @State private var agent = ""
    @State private var title = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Run 3 times", text: $title, axis: .vertical).lineLimit(1...3)
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
                            await save(NewObjective(agent: agent, period: period,
                                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines)))
                            dismiss()
                        }
                    }
                    .disabled(saving || agent.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if agent.isEmpty { agent = agents.first?.id ?? "" } }
        }
        .presentationDetents([.medium])
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
