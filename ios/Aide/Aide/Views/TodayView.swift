import SwiftUI

/// Where Today scrolls to when a notification or a link opens it.
enum TodayFocus: Equatable {
    case top, digest, habits, notes
}

/// The Today tab (#21): one page for the day instead of a digest in the chat, the bell and the Objectives tab. From
/// the top (opened from the strip on the Team tab): the latest digest as a card, everything waiting for your OK (a
/// period's proposals as one plan card), the week's goals (each with its days and today's step), today's other
/// objectives, habits, the month as a strip, then the team's notes from routines and watches, with the whole
/// activity feed behind them. Each part loads on its own (docs/API.md, "Today", "Objectives").
struct TodayView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digest: DigestViewModel
    @EnvironmentObject private var push: PushService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// Things waiting for your OK, for the tab's badge.
    @Binding var waiting: Int
    /// Only the objectives (with their plans waiting): the Mac's Objectives section. False: the whole page.
    var objectivesOnly = false

    @State private var approvals: Approvals?
    @State private var habits: [Habit] = []
    @State private var habitsLoaded = false
    @State private var overview: ObjectivesOverview?
    @State private var notes: [ActivityItem] = []
    @State private var notesLoaded = false
    @State private var error: String?
    /// The period being planned now.
    @State private var planning: String?
    @State private var addingObjective = false
    @State private var opened: Objective?
    @State private var addingHabit = false
    @State private var editingHabit: Habit?
    @State private var showHabits = false
    @State private var showActivity = false
    /// Picked in the Activity sheet; opened once it's gone.
    @State private var openAfterActivity: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                page
                .scrollContentBackground(.hidden)
                .pageGlow(Theme.accent)
                .navigationTitle(objectivesOnly ? "Objectives" : "Today")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { addMenu }
                    #if os(iOS)
                    // A sheet over Team on the phone; a section of the window on the Mac, with nothing to close.
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    #endif
                }
                .navigationDestination(isPresented: $showHabits) { HabitsScreen(habits: $habits).macPageBack() }
                .onChange(of: env.todayFocus, initial: true) { _, focus in
                    guard let focus else { return }
                    env.todayFocus = nil
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
                   let o = allObjectives.first(where: { $0.title.localizedCaseInsensitiveContains(n) }) { opened = o }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
            .sheet(isPresented: $addingObjective) {
                NewObjectiveSheet(period: "week", agents: chat.agents.filter { !$0.orchestrator }) { await add($0) }
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
            .sheet(isPresented: $digest.isPresented) { DigestSheet() } // the Team tab's can't show over this page
            .sheet(isPresented: $showActivity, onDismiss: afterActivity) {
                ActivitySheet(agent: nil, open: { id in openAfterActivity = id; showActivity = false }, showsWaiting: false)
            }
        }
        .onChange(of: approvals?.waiting) { _, n in if let n { waiting = n } }
    }

    /// The phone: one list from the digest down. The Mac: the day and its goals, with what's waiting, the habits and
    /// the team's notes beside them (Objectives: the goals, with the plans waiting and the month beside them).
    @ViewBuilder private var page: some View {
        #if os(macOS)
        MacSplitList {
            if !settings.isConfigured {
                Section { Text("Add your server token in Settings to start.").foregroundStyle(.secondary) }
            }
            if !objectivesOnly { digestSection.id(TodayFocus.digest) }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            if let overview {
                weekSection(overview)
                todaySection(overview)
                if !objectivesOnly { monthSection(overview) }
            } else if settings.isConfigured && error == nil {
                SkeletonSections(sections: 1, rows: 2)
            }
        } side: {
            if objectivesOnly {
                if let overview {
                    plansSection(overview)
                    monthSection(overview)
                }
            } else {
                WaitingSection(approvals: approvals, agent: nil, reload: { await loadApprovals() }) { open($0) }
                habitsSection.id(TodayFocus.habits)
                notesSection.id(TodayFocus.notes)
            }
        }
        #else
        List {
            if !settings.isConfigured {
                Section { Text("Add your server token in Settings to start.").foregroundStyle(.secondary) }
            }
            if !objectivesOnly {
                digestSection.id(TodayFocus.digest)
                WaitingSection(approvals: approvals, agent: nil, reload: { await loadApprovals() }) { open($0) }
            }
            objectivesSection
            if !objectivesOnly { notesSection.id(TodayFocus.notes) }
        }
        #endif
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
            } header: {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.medium))
                    .textCase(nil)
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

    @ViewBuilder private var habitsSection: some View {
        if settings.isConfigured {
            Section {
                if !habitsLoaded {
                    ForEach(0..<2, id: \.self) { i in SkeletonRow(widths: SkeletonRow.widths[i]) }
                } else if habits.isEmpty {
                    Button("Add a habit", systemImage: "plus") { addingHabit = true }
                }
                ForEach(habits.sorted { !$0.isLimit && $1.isLimit }) { habit in // the counted ones last
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

    /// The week is the page: its goals as cards with today's steps inside, then today's other objectives, the
    /// habits, and the month as a strip. Proposals wait in their plan card (in Waiting for you; here, on the
    /// Mac's own page).
    @ViewBuilder private var objectivesSection: some View {
        if let error {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
        }
        if let overview {
            if objectivesOnly { plansSection(overview) }
            weekSection(overview)
            todaySection(overview)
            if !objectivesOnly { habitsSection.id(TodayFocus.habits) }
            monthSection(overview)
        } else if settings.isConfigured && error == nil {
            SkeletonSections(sections: 1, rows: 2)
        }
    }

    /// Each period's proposals as one plan card (the Mac's Objectives page; elsewhere they're in Waiting for you).
    @ViewBuilder private func plansSection(_ overview: ObjectivesOverview) -> some View {
        let plans = ["day", "week", "month"].compactMap { p -> ObjectiveBlock? in
            var b = overview[p]
            b.objectives = b.proposed
            return b.objectives.isEmpty ? nil : b
        }
        if !plans.isEmpty {
            Section {
                ForEach(plans, id: \.period) { plan in
                    ObjectivePlanCard(plan: plan) { await loadObjectives(); await loadApprovals() }
                }
            } header: { Text("Waiting for you") }
            .listRowBackground(Theme.row)
        }
    }

    private func weekSection(_ overview: ObjectivesOverview) -> some View {
        let week = overview.week
        let goals = week.objectives.filter { !$0.isProposed }
        let today = overview.day.objectives.filter { !$0.isProposed }
        return Section {
            ForEach(goals) { goal in
                WeekGoalCard(goal: goal, agent: chat.agent(goal.agent), steps: today.filter { $0.parent == goal.id },
                             tick: { o in Task { await tick(o) } }, open: { opened = $0 })
                    .swipeActions(edge: .trailing) {
                        if !goal.isLapsed { Button("Drop", role: .destructive) { Task { await drop(goal) } } }
                    }
            }
            if goals.isEmpty {
                Text(emptyText(week)).font(.subheadline).foregroundStyle(.secondary)
                if !week.planned || week.objectives.isEmpty { proposeButton("week") }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("This week")
                Spacer()
                Text(ObjectiveDates.span(week)).textCase(nil)
            }
        } footer: {
            if !goals.isEmpty { Text(weekSummary(goals, week)) }
        }
        .listRowBackground(Theme.row)
    }

    /// Today's objectives that aren't a week goal's step. Nothing when there are none.
    @ViewBuilder private func todaySection(_ overview: ObjectivesOverview) -> some View {
        let goals = Set(overview.week.objectives.filter { !$0.isProposed }.map(\.id))
        let loose = overview.day.objectives.filter { !$0.isProposed && !goals.contains($0.parent ?? "") }
        if !loose.isEmpty {
            Section {
                ForEach(loose) { o in
                    let agent = chat.agent(o.agent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(agent.tint)
                        ObjectiveRow(objective: o, tint: agent.tint, tick: { Task { await tick(o) } }, open: { opened = o })
                    }
                    .swipeActions(edge: .trailing) {
                        if !o.isLapsed { Button("Drop", role: .destructive) { Task { await drop(o) } } }
                    }
                }
            } header: {
                Text("Also today")
            }
            .listRowBackground(Theme.row)
        }
    }

    /// The month, small: a bar per goal. Left out when it's planned and has none.
    @ViewBuilder private func monthSection(_ overview: ObjectivesOverview) -> some View {
        let month = overview.month
        let goals = month.objectives.filter { !$0.isProposed }
        if !goals.isEmpty || !month.planned {
            Section {
                ForEach(goals) { goal in
                    MonthGoalRow(goal: goal, agent: chat.agent(goal.agent),
                                 tick: { Task { await tick(goal) } }, open: { opened = goal })
                        .swipeActions(edge: .trailing) {
                            if !goal.isLapsed { Button("Drop", role: .destructive) { Task { await drop(goal) } } }
                        }
                }
                if goals.isEmpty {
                    Text(emptyText(month)).font(.subheadline).foregroundStyle(.secondary)
                    proposeButton("month")
                }
            } header: {
                Text(ObjectiveDates.date(month.start)?.formatted(.dateTime.month(.wide)) ?? "This month")
            }
            .listRowBackground(Theme.row)
        }
    }

    /// "1 of 3 done · 5 days left".
    private func weekSummary(_ goals: [Objective], _ week: ObjectiveBlock) -> String {
        let done = goals.filter(\.done).count
        var out = "\(done) of \(goals.count) done"
        if let end = ObjectiveDates.date(week.end) {
            let left = (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: end).day ?? 0) + 1
            out += left == 1 ? " · last day" : " · \(left) days left"
        }
        return out
    }

    private func emptyText(_ block: ObjectiveBlock) -> String {
        let period = block.period
        if !block.proposed.isEmpty {
            let above = objectivesOnly ? "above" : "in Waiting for you"
            return "The plan for \(ObjectiveDates.this(period)) is \(above). " + ObjectiveDates.starts(block.startsAt) + "."
        }
        if block.planned { return "Nothing set for \(ObjectiveDates.this(period)). Add one, or ask the team for a plan." }
        return "Not planned yet. The team proposes \(ObjectiveDates.when(period)), or now:"
    }

    private func proposeButton(_ period: String) -> some View {
        Button { Task { await plan(period) } } label: {
            HStack {
                Label("Propose \(ObjectiveDates.this(period))'s objectives", systemImage: "sparkles")
                if planning == period { Spacer(); ProgressView() }
            }
        }
        .disabled(planning != nil)
    }

    private var addMenu: some View {
        Menu {
            Button("Add an objective", systemImage: "scope") { addingObjective = true }
            Button("Add a habit", systemImage: "flame") { addingHabit = true }
            Menu {
                Button("For today") { Task { await plan("day") } }
                Button("For this week") { Task { await plan("week") } }
                Button("For this month") { Task { await plan("month") } }
            } label: {
                Label("Propose new objectives", systemImage: "sparkles")
            }
            .disabled(planning != nil)
        } label: {
            if planning != nil { ProgressView() } else { Image(systemName: "plus") }
        }
        .accessibilityLabel("Add or propose")
        .disabled(!settings.isConfigured)
    }

    private var allObjectives: [Objective] {
        guard let overview else { return [] }
        return overview.day.objectives + overview.week.objectives + overview.month.objectives
    }

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

    private func accept(_ o: Objective) async {
        do {
            _ = try await env.api.acceptObjectives(period: o.period, date: o.start, ids: [o.id])
            await loadObjectives()
            error = nil
        } catch { self.error = describe(error) }
    }

    private func drop(_ o: Objective) async {
        do { replace(try await env.api.updateObjective(o.id, ObjectivePatch(status: "dropped"))); error = nil }
        catch { self.error = describe(error) }
    }

    private func plan(_ period: String) async {
        guard let block = overview?[period] else { return }
        planning = period
        defer { planning = nil }
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
            case .sleep(let night, let usual, _):
                var text = "\(SleepCard.duration(night.asleepMin)) asleep"
                if let usual, abs(night.asleepMin - usual) >= 15 {
                    let gap = SleepCard.duration(abs(night.asleepMin - usual))
                    text += night.asleepMin < usual ? " · \(gap) under your usual" : " · \(gap) over your usual"
                }
                out.append(Line(icon: "moon.zzz.fill", color: .indigo, text: text))
            case .bedtime(let plan):
                if let bed = plan.bedtimeDate, let wake = plan.wakeDate {
                    out.append(Line(icon: "bed.double.fill", color: .indigo,
                                    text: "In bed by \(BedtimeCard.time(bed)) · up at \(BedtimeCard.time(wake))"))
                }
            case .weather(let weather):
                let now = weather.now.map { "\($0.temp)° now · " } ?? ""
                out.append(Line(icon: WeatherCard.icon(weather.now?.symbol ?? weather.symbol), color: .cyan,
                                text: now + weather.summary))
            case .calendar(let events):
                let upcoming = events.filter { $0.allDay || ($0.startDate ?? .distantFuture) > Date() }
                for event in upcoming.prefix(2) {
                    let time = event.allDay ? "All day" : event.startDate?.formatted(date: .omitted, time: .shortened) ?? ""
                    out.append(Line(icon: "calendar", color: event.tint,
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
