import SwiftUI

/// Where Today scrolls to when a notification or a link opens it.
enum TodayFocus: Equatable {
    case top, digest, habits, notes
}

/// The Today tab (#21): one page for the day instead of a digest in the chat, the bell and the Objectives tab. From
/// the top: the latest digest as a card, everything waiting for your OK, habits and objectives (Today / Week /
/// Month), then the team's notes from routines and watches, with the whole activity feed behind them. Each part
/// loads on its own (docs/API.md, "Today").
struct TodayView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digest: DigestViewModel
    @EnvironmentObject private var push: PushService
    @Environment(\.scenePhase) private var scenePhase
    /// Things waiting for your OK, for the tab's badge.
    @Binding var waiting: Int

    @State private var approvals: Approvals?
    @State private var habits: [Habit] = []
    @State private var habitsLoaded = false
    @State private var overview: ObjectivesOverview?
    @State private var period = "day"
    @State private var notes: [ActivityItem] = []
    @State private var notesLoaded = false
    @State private var error: String?
    @State private var planning = false
    @State private var addingObjective = false
    @State private var opened: Objective?
    @State private var addingHabit = false
    @State private var editingHabit: Habit?
    @State private var showHabits = false
    @State private var showActivity = false
    /// Picked in the Activity sheet; opened once it's gone.
    @State private var openAfterActivity: String?

    private static let periods = [("day", "Today"), ("week", "Week"), ("month", "Month")]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !settings.isConfigured {
                        Section { Text("Add your server token in Settings to start.").foregroundStyle(.secondary) }
                    }
                    digestSection.id(TodayFocus.digest)
                    WaitingSection(approvals: approvals, agent: nil, reload: { await loadApprovals() }) { open($0) }
                    planSection.id(TodayFocus.habits)
                    if period == "day" { habitsSection }
                    objectivesSection
                    notesSection.id(TodayFocus.notes)
                }
                .scrollContentBackground(.hidden)
                .background(Theme.grouped)
                .navigationTitle("Today")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { addMenu } }
                .navigationDestination(isPresented: $showHabits) { HabitsScreen(habits: $habits) }
                .onChange(of: env.todayFocus, initial: true) { _, focus in
                    guard let focus else { return }
                    env.todayFocus = nil
                    if focus == .habits { period = "day" }
                    Task {
                        if focus == .digest { await digest.loadLatest() }
                        if focus == .notes { await loadNotes() }
                        try? await Task.sleep(for: .milliseconds(150)) // let the tab switch first
                        withAnimation { proxy.scrollTo(focus == .top ? TodayFocus.digest : focus, anchor: .top) }
                    }
                }
            }
            .refreshable { await load() }
            .task {
                await load()
                #if DEBUG
                // Simulator screenshots: `-previewFocus habits` or `notes`.
                switch settings.isPreview ? UserDefaults.standard.string(forKey: "previewFocus") : nil {
                case "habits": env.todayFocus = .habits
                case "notes": env.todayFocus = .notes
                default: break
                }
                if settings.isPreview, let n = UserDefaults.standard.string(forKey: "previewObjective"),
                   let o = block?.objectives.first(where: { $0.title.localizedCaseInsensitiveContains(n) }) { opened = o }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
            .sheet(isPresented: $addingObjective) {
                NewObjectiveSheet(period: period, agents: chat.agents.filter { !$0.orchestrator }) { await add($0) }
            }
            .sheet(item: $opened) { o in
                ObjectiveDetailSheet(objective: o, agent: chat.agent(o.agent),
                                     tick: { await tick($0) }, update: { await update($0, $1) })
            }
            .sheet(isPresented: $addingHabit) {
                HabitSheet(habit: nil) { new in
                    do { habits.append(try await env.api.addHabit(new)); return nil } catch { return error.localizedDescription }
                }
            }
            .sheet(item: $editingHabit) { habit in
                HabitSheet(habit: habit) { changes in
                    do {
                        HabitActions.replace(try await env.api.updateHabit(habit.id, changes), in: $habits)
                        return nil
                    } catch { return error.localizedDescription }
                }
            }
            .sheet(isPresented: $showActivity, onDismiss: afterActivity) {
                ActivitySheet(agent: nil, open: { id in openAfterActivity = id; showActivity = false }, showsWaiting: false)
            }
        }
        .onChange(of: approvals?.waiting) { _, n in if let n { waiting = n } }
    }

    // MARK: Digest

    @ViewBuilder private var digestSection: some View {
        if settings.isConfigured {
            Section {
                if let latest = digest.latest {
                    DigestCard(digest: latest, details: { digest.showLatest() }, reply: { Task { await reply(latest) } })
                } else if !digest.latestLoaded {
                    SkeletonText(paragraphs: 2).padding(.vertical, 6)
                } else {
                    Text("No digest yet. The morning one comes with your wake-up, or at its time in Settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// A chat with Aide that starts from this digest's greeting.
    private func reply(_ latest: Digest) async {
        await chat.startNewChat(digest: latest.kind)
        push.route = .chats
    }

    // MARK: Habits and objectives

    private var planSection: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Habits and objectives")
        } footer: {
            if let block { Text(ObjectiveDates.span(block)).font(.subheadline) }
        }
    }

    @ViewBuilder private var habitsSection: some View {
        if settings.isConfigured {
            Section {
                if !habitsLoaded {
                    ForEach(0..<2, id: \.self) { i in SkeletonRow(widths: SkeletonRow.widths[i]) }
                } else if habits.isEmpty {
                    Button("Add a habit", systemImage: "plus") { addingHabit = true }
                }
                ForEach(habits) { habit in
                    HabitRow(habit: habit,
                             toggle: { Task { await HabitActions.toggle(habit, in: $habits, env: env, error: $error) } },
                             count: { n in Task { await HabitActions.count(habit, n, in: $habits, env: env, error: $error) } },
                             edit: { editingHabit = habit }, showsGrid: false)
                }
            } header: {
                HStack {
                    Text("Habits")
                    Spacer()
                    if !habits.isEmpty {
                        Button("All") { showHabits = true }.font(.subheadline.weight(.semibold)).textCase(nil)
                    }
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// The period's objectives, proposals left to Waiting for you.
    @ViewBuilder private var objectivesSection: some View {
        if let error {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
        }
        if let block {
            let shown = block.objectives.filter { !$0.isProposed }
            Section {
                ForEach(shown) { o in
                    let agent = chat.agent(o.agent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(agent.tint)
                        ObjectiveRow(objective: o, tint: agent.tint, tick: { Task { await tick(o) } }, open: { opened = o })
                    }
                    .swipeActions(edge: .trailing) {
                        if !o.isLapsed { Button("Drop", role: .destructive) { Task { await drop(o) } } }
                    }
                }
                if shown.isEmpty {
                    Text(emptyText(block)).font(.subheadline).foregroundStyle(.secondary)
                    if !block.planned || block.objectives.isEmpty { proposeButton }
                }
            } header: {
                Text("Objectives")
            }
            .listRowBackground(Theme.row)
        } else if settings.isConfigured && error == nil {
            SkeletonSections(sections: 1, rows: 2)
        }
    }

    private func emptyText(_ block: ObjectiveBlock) -> String {
        if !block.proposed.isEmpty { return "Proposals are waiting for your OK above." }
        if block.planned { return "Nothing set for \(ObjectiveDates.this(period)). Add one, or ask the team for a plan." }
        return "Not planned yet. The team proposes \(ObjectiveDates.when(period)), or now:"
    }

    private var proposeButton: some View {
        Button { Task { await plan() } } label: {
            HStack {
                Label("Propose \(ObjectiveDates.this(period))'s objectives", systemImage: "sparkles")
                if planning { Spacer(); ProgressView() }
            }
        }
        .disabled(planning)
    }

    private var addMenu: some View {
        Menu {
            Button("Add an objective", systemImage: "scope") { addingObjective = true }
            Button("Add a habit", systemImage: "flame") { addingHabit = true }
            Button("Propose new objectives", systemImage: "sparkles") { Task { await plan() } }
                .disabled(planning)
        } label: {
            if planning { ProgressView() } else { Image(systemName: "plus") }
        }
        .accessibilityLabel("Add or propose")
        .disabled(!settings.isConfigured)
    }

    private var block: ObjectiveBlock? { overview?[period] }

    // MARK: Notes

    @ViewBuilder private var notesSection: some View {
        if settings.isConfigured {
            Section {
                if !notesLoaded {
                    SkeletonRow(widths: SkeletonRow.widths[0])
                } else if notes.isEmpty {
                    Text("Nothing yet. What your routines and watches find shows up here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(notes) { item in
                    Button { open(item.conversationId) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ActivityRow(item: item, agent: chat.agent(item.agent), showsAgent: true)
                            if let date = item.date, !Calendar.current.isDateInToday(date) {
                                Text(ActivityDays.title(Calendar.current.startOfDay(for: date)))
                                    .font(.caption).foregroundStyle(.tertiary).padding(.leading, 40)
                            }
                        }
                    }
                    .disabled(item.conversationId == nil)
                }
                Button { showActivity = true } label: {
                    Label("All activity", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("From the team")
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Loading

    private func load() async {
        guard settings.isConfigured else { return }
        async let approvals: Void = loadApprovals()
        async let habits: Void = loadHabits()
        async let objectives: Void = loadObjectives()
        async let notes: Void = loadNotes()
        async let latest: Void = digest.loadLatest()
        await approvals
        await habits
        await objectives
        await notes
        await latest
    }

    private func loadApprovals() async {
        if let a = try? await env.api.approvals() { approvals = a } // an older server: nothing waits
    }

    private func loadHabits() async {
        do { habits = try await env.api.habits() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        habitsLoaded = true
    }

    private func loadObjectives() async {
        do { overview = try await env.api.objectives() } catch { if !Task.isCancelled { self.error = describe(error) } }
    }

    private func loadNotes() async {
        if let page = try? await env.api.activity(kinds: ["routine", "watch"], limit: 8) { notes = page.items }
        notesLoaded = true
    }

    private func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't have objectives yet. Update the server first." }
        return error.localizedDescription
    }

    /// A chat by id ("team" and "main" too), opened in the Chats tab.
    private func open(_ id: String?) {
        guard let id else { return }
        switch id {
        case "team": push.route = .team
        case "main": push.route = .agent("aide")
        default: push.route = .conversation(id)
        }
    }

    private func afterActivity() {
        Task { await loadApprovals() } // answered something: the badge may have changed
        guard let id = openAfterActivity else { return }
        openAfterActivity = nil
        open(id)
    }

    // MARK: Objectives

    private func replace(_ o: Objective) {
        guard var block = overview?[o.period] else { return }
        if let i = block.objectives.firstIndex(where: { $0.id == o.id }) {
            if o.status == "dropped" { block.objectives.remove(at: i) } else { block.objectives[i] = o }
        } else {
            block.objectives.append(o)
        }
        overview?[o.period] = block
    }

    @discardableResult
    private func tick(_ o: Objective) async -> Objective? {
        defer { if o.reminderID != nil { Task { await env.sync.sync() } } }
        do {
            let updated = try await env.api.tickObjective(o)
            replace(updated); error = nil
            return updated
        } catch { self.error = describe(error); return nil }
    }

    private func update(_ o: Objective, _ patch: ObjectivePatch) async -> Objective? {
        do {
            let updated = try await env.api.updateObjective(o.id, patch)
            replace(updated); error = nil
            return updated
        } catch { self.error = describe(error); return nil }
    }

    private func drop(_ o: Objective) async {
        do { replace(try await env.api.updateObjective(o.id, ObjectivePatch(status: "dropped"))); error = nil }
        catch { self.error = describe(error) }
    }

    private func plan() async {
        guard let block else { return }
        planning = true
        defer { planning = false }
        do {
            overview?[block.period] = try await env.api.planObjectives(period: block.period, date: block.start)
            error = nil
            await loadApprovals() // the new proposals wait there
        } catch { self.error = describe(error) }
    }

    private func add(_ new: NewObjective) async {
        do { replace(try await env.api.addObjective(new)); error = nil } catch { self.error = describe(error) }
    }
}

/// The latest digest on Today, kept small: which one and when, three lines of the greeting, then a line each for
/// last night and what's next. Tapping it opens the whole digest; the bubble starts a chat with Aide about it.
private struct DigestCard: View {
    @EnvironmentObject private var model: DigestViewModel
    let digest: Digest
    let details: () -> Void
    let reply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sun.horizon.fill").foregroundStyle(Theme.accent)
                Text(heading).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: reply) {
                    Image(systemName: "bubble.left").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reply")
            }
            Button(action: details) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(digest.greeting.markdown).font(.subheadline).lineSpacing(2).lineLimit(3)
                        .multilineTextAlignment(.leading)
                    ForEach(lines, id: \.text) { line in
                        Label {
                            Text(line.text).lineLimit(1)
                        } icon: {
                            Image(systemName: line.icon).foregroundStyle(line.color)
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private struct Line { let icon: String; let color: Color; let text: String }

    /// Last night, the next two events, the reminders due: one line each.
    private var lines: [Line] {
        var out: [Line] = []
        for section in digest.sections {
            switch section.content {
            case .sleep(let night, let usual):
                var text = "\(SleepCard.duration(night.asleepMin)) asleep"
                if let usual, abs(night.asleepMin - usual) >= 15 {
                    let gap = SleepCard.duration(abs(night.asleepMin - usual))
                    text += night.asleepMin < usual ? " · \(gap) under your usual" : " · \(gap) over your usual"
                }
                out.append(Line(icon: "moon.zzz.fill", color: .indigo, text: text))
            case .calendar(let events):
                let upcoming = events.filter { $0.allDay || ($0.startDate ?? .distantFuture) > Date() }
                for event in upcoming.prefix(2) {
                    let time = event.allDay ? "All day" : event.startDate?.formatted(date: .omitted, time: .shortened) ?? ""
                    out.append(Line(icon: "calendar", color: Theme.tint(for: event.calendar ?? event.title),
                                    text: "\(time) \(event.title)"))
                }
                if upcoming.count > 2 {
                    out.append(Line(icon: "ellipsis", color: .secondary, text: "\(upcoming.count - 2) more today"))
                }
            case .reminders(let reminders) where !reminders.isEmpty:
                let open = reminders.filter { !$0.completed }
                if !open.isEmpty {
                    out.append(Line(icon: "checklist", color: .orange,
                                    text: open.count == 1 ? open[0].title : "\(open.count) reminders"))
                }
            default: break
            }
        }
        return out
    }

    /// "Morning · 08:02", "Evening · yesterday 22:00".
    private var heading: String {
        let name = DigestViewModel.Kind(rawValue: digest.kind)?.label ?? digest.kind.capitalized
        guard let at = digest.generatedAt.flatMap(Wire.parse) else { return name }
        let time = at.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(at) { return "\(name) · \(time)" }
        if Calendar.current.isDateInYesterday(at) { return "\(name) · yesterday \(time)" }
        return "\(name) · \(at.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}
