import SwiftUI

/// Whose activity the sheet shows.
enum ActivityScope: Identifiable {
    case everyone
    case agent(Agent)

    var id: String {
        switch self {
        case .everyone: "everyone"
        case .agent(let agent): agent.id
        }
    }

    var agent: Agent? {
        if case .agent(let agent) = self { return agent }
        return nil
    }
}

/// What the team did and what's waiting for you, in one place outside the chats (docs/API.md, "Activity and
/// approvals"). On top, what's waiting for your OK (`WaitingSection`; left out from Today, which shows it itself),
/// then the routines coming up, then the activity by day. Opened from Today's "All activity" for everyone, or from
/// an agent's card for that agent alone.
struct ActivitySheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    /// nil: the whole team.
    @State var agent: Agent?
    /// A chat to open once the sheet is gone: a chat id, "main" or "team".
    let open: (String) -> Void

    @State private var approvals: Approvals?
    @State private var items: [ActivityItem] = []
    @State private var next: Int?
    @State private var loaded = false
    @State private var error: String?
    /// False on Today, which shows what's waiting above its own link here.
    var showsWaiting = true

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
                }
                if showsWaiting {
                    WaitingSection(approvals: approvals, agent: agent, reload: { await load() }, open: go)
                }
                upcomingSection
                ForEach(ActivityDays.group(items), id: \.day) { group in
                    Section(ActivityDays.title(group.day)) {
                        ForEach(group.items) { item in
                            Button { go(item.conversationId) } label: {
                                ActivityRow(item: item, agent: chat.agent(item.agent), showsAgent: agent == nil)
                                    .multilineTextAlignment(.leading) // the Mac centres a button's lines
                            }
                            .disabled(item.conversationId == nil)
                            .listRowBackground(Theme.row)
                        }
                    }
                }
                if let next {
                    Button("Show earlier") { Task { await loadMore(before: next) } }
                        .listRowBackground(Theme.row)
                } else if loaded && items.isEmpty {
                    Section {
                        Text(agent.map { "Nothing from \($0.name) yet." } ?? "Nothing yet. What the team does shows up here.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !loaded && error == nil {
                    SkeletonSections(sections: 2, rows: 3)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(agent.map { "\($0.name)'s activity" } ?? "Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filter }
            }
            .refreshable { await load() }
            .task(id: agent?.id) { await load() }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.grouped)
    }

    // MARK: Coming up

    @ViewBuilder private var upcomingSection: some View {
        let routines = (approvals?.upcoming ?? []).filter(mine(\.agent))
        if !routines.isEmpty {
            Section("Coming up") {
                ForEach(routines) { r in
                    Button { go(r.conversationId) } label: {
                        HStack(spacing: 10) {
                            AgentMark(agent: chat.agent(r.agent), size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).foregroundStyle(.primary)
                                Text(r.isWatch ? "Keeps an eye on" : "Routine").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if let when = r.nextRun.flatMap(Wire.parse) {
                                Text(ActivityDays.upcoming(when)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.row)
                }
            }
        }
    }

    private var filter: some View {
        Menu {
            Picker("Who", selection: Binding(get: { agent?.id ?? "" },
                                             set: { id in agent = id.isEmpty ? nil : chat.agent(id) })) {
                Text("Everyone").tag("")
                ForEach(chat.agents) { Text($0.name).tag($0.id) }
            }
        } label: {
            Image(systemName: agent == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Show one agent")
    }

    private func go(_ id: String?) {
        if let id { open(id) }
    }

    private func mine<T>(_ key: KeyPath<T, String>) -> (T) -> Bool {
        { agent == nil || $0[keyPath: key] == agent?.id }
    }

    // MARK: Loading and answering

    private func load() async {
        async let waiting = env.api.approvals()
        async let page = env.api.activity(agent: agent?.id)
        do {
            let (w, p) = try await (waiting, page)
            approvals = w
            items = p.items
            next = p.next
            error = nil
        } catch {
            self.error = describe(error)
        }
        loaded = true
    }

    private func loadMore(before: Int) async {
        do {
            let page = try await env.api.activity(agent: agent?.id, before: before)
            items += page.items
            next = page.next
        } catch { self.error = describe(error) }
    }

    private func describe(_ error: Error) -> String { WaitingSection.describe(error) }
}

/// Everything waiting for your OK, as one list section: queued actions (each confirmed or cancelled on its own),
/// reply drafts (sent with a tap, or edited first), proposed objectives, notebook proposals, a paused notes job.
/// Shown on Today, and in an agent's Activity sheet for that agent alone. Nothing at all when nothing waits.
struct WaitingSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    let approvals: Approvals?
    /// nil: the whole team.
    let agent: Agent?
    /// Loads the approvals again after an answer.
    let reload: () async -> Void
    /// A chat to open: a chat id, "main" or "team".
    let open: (String?) -> Void

    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var editing: MailDraft?
    @State private var browser: BrowserTarget?
    @State private var reviewing: QueuedAction?

    var body: some View {
        let actions = (approvals?.actions ?? []).filter(mine(\.agent))
        let drafts = (approvals?.drafts ?? []).filter(mine(\.agent))
        let objectives = (approvals?.objectives ?? []).filter(mine(\.agent))
        let proposals = agent == nil || agent?.id == "professor" ? approvals?.proposals ?? [] : []
        let writer = agent == nil || agent?.id == "professor" ? approvals?.writer : nil
        let errands = agent == nil || agent?.id == "aide" ? approvals?.errands ?? [] : []
        // Orders are confirmed one at a time, from their own page.
        let plain = actions.filter { $0.purchase == nil }
        if !actions.isEmpty || !drafts.isEmpty || !objectives.isEmpty || !proposals.isEmpty || writer != nil
            || !errands.isEmpty {
            Section {
                ForEach(errands) { e in
                    ErrandWaitingRow(errand: e, agent: chat.agent("aide"), busy: busy.contains("e\(e.id)"),
                                     takeOver: { browser = .errand(e.id, title: e.title) },
                                     answer: { text in Task { await act("e\(e.id)") { _ = try await env.api.replyErrand(e.id, answer: text); return nil } } },
                                     cancel: { Task { await act("e\(e.id)") { _ = try await env.api.cancelErrand(e.id); return nil } } })
                        .contentShape(Rectangle())
                        .onTapGesture { go(e.conversationId) }
                        .listRowBackground(Theme.row)
                }
                ForEach(actions) { action in
                    QueuedActionRow(action: action, agent: chat.agent(action.agent), busy: busy.contains("a\(action.id)"),
                                    confirm: {
                                        if action.purchase != nil { reviewing = action } else { Task { await decide(action, confirm: true) } }
                                    },
                                    cancel: { Task { await decide(action, confirm: false) } })
                        .contentShape(Rectangle())
                        .onTapGesture { if action.purchase != nil { reviewing = action } else { go(action.conversationId) } }
                        .listRowBackground(Theme.row)
                }
                if plain.count > 1 {
                    Button { Task { await confirmAll(plain) } } label: {
                        Label("Confirm all \(plain.count)", systemImage: "checkmark").font(.body.weight(.semibold))
                    }
                    .disabled(!busy.isEmpty)
                    .listRowBackground(Theme.row)
                }
                ForEach(drafts) { draft in
                    DraftRow(draft: draft, agent: chat.agent(draft.agent), busy: busy.contains("d\(draft.id)"),
                             send: { Task { error = await answer(draft, send: draft.body) } },
                             edit: { editing = draft },
                             dismiss: { Task { error = await answer(draft, send: nil) } })
                        .listRowBackground(Theme.row)
                }
                ForEach(objectives) { o in
                    HStack(alignment: .top, spacing: 10) {
                        AgentMark(agent: chat.agent(o.agent), size: 22).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(o.title)
                            Text([ObjectiveDates.this(o.period).capitalizedFirst, o.why].compactMap { $0 }
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .leading) {
                        Button("Accept") { Task { await accept([o]) } }.tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Drop", role: .destructive) { Task { await drop(o) } }
                    }
                    .listRowBackground(Theme.row)
                }
                if !objectives.isEmpty {
                    Button { Task { await accept(objectives) } } label: {
                        Label(objectives.count == 1 ? "Accept the objective" : "Accept all \(objectives.count) objectives",
                              systemImage: "scope").font(.body.weight(.semibold))
                    }
                    .disabled(busy.contains("objectives"))
                    .listRowBackground(Theme.row)
                }
                ForEach(proposals) { p in
                    ProposalRow(proposal: p, agent: chat.agent("professor"), busy: busy.contains(p.id),
                                apply: { Task { await answer(p, apply: true) } },
                                decline: { Task { await answer(p, apply: false) } })
                        .contentShape(Rectangle())
                        .onTapGesture { go(p.conversationId) }
                        .listRowBackground(Theme.row)
                }
                if let writer {
                    WriterPauseCard(pause: writer) { _ in Task { await load() } }
                        .listRowBackground(Theme.row)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                        .listRowBackground(Theme.row)
                }
            } header: {
                Text("Waiting for you")
            } footer: {
                if !objectives.isEmpty { Text("Swipe an objective to accept or drop it on its own.") }
            }
            .sheet(item: $editing) { draft in
                DraftEditor(draft: draft, send: { await answer(draft, send: $0) }, dismiss: { await answer(draft, send: nil) })
            }
            .sheet(item: $reviewing) { action in
                PurchaseConfirmSheet(action: action) { await load() }
            }
            .stage(item: $browser, tint: chat.agent("aide").tint) { Task { await load() } }
        }
    }

    private func go(_ id: String?) { open(id) }

    private func mine<T>(_ key: KeyPath<T, String>) -> (T) -> Bool {
        { agent == nil || $0[keyPath: key] == agent?.id }
    }

    static func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't have the activity feed yet. Update the server first." }
        return error.localizedDescription
    }

    private func describe(_ error: Error) -> String { Self.describe(error) }

    private func load() async { await reload() }

    /// Answers, then reloads everything: one answer can change the feed and the rest of the queue. `call` returns
    /// a problem to show, or nil.
    private func act(_ key: String, _ call: () async throws -> String?) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do { error = try await call() } catch { self.error = describe(error) }
        await load()
    }

    private func decide(_ action: QueuedAction, confirm: Bool) async {
        await act("a\(action.id)") {
            guard confirm else { _ = try await env.api.cancel(ids: [action.id]); return nil }
            let result = try await env.api.confirm(ids: [action.id]).result
            return result.contains("✗") ? result : nil
        }
        if confirm { await env.sync.sync() } // it may have changed reminders
    }

    /// Sends a draft (with `send`, its text as it should go) or dismisses it (nil). A problem to show, or nil.
    private func answer(_ draft: MailDraft, send text: String?) async -> String? {
        busy.insert("d\(draft.id)")
        defer { busy.remove("d\(draft.id)") }
        do {
            if let text { _ = try await env.api.sendDraft(draft.id, body: text) } else { try await env.api.dismissDraft(draft.id) }
        } catch { return describe(error) }
        await load()
        return nil
    }

    private func confirmAll(_ actions: [QueuedAction]) async {
        await act("all") {
            let result = try await env.api.confirm(ids: actions.map(\.id)).result
            return result.contains("✗") ? result : nil
        }
        await env.sync.sync()
    }

    /// Accepted a period at a time: the server takes one period's ids per call.
    private func accept(_ objectives: [Objective]) async {
        await act("objectives") {
            for group in Dictionary(grouping: objectives, by: { "\($0.period) \($0.start)" }).values {
                guard let first = group.first else { continue }
                _ = try await env.api.acceptObjectives(period: first.period, date: first.start, ids: group.map(\.id))
            }
            return nil
        }
    }

    private func drop(_ o: Objective) async {
        await act(o.id) { _ = try await env.api.updateObjective(o.id, ObjectivePatch(status: "dropped")); return nil }
    }

    private func answer(_ p: NotebookProposal, apply: Bool) async {
        await act(p.id) {
            _ = apply ? try await env.api.applyProposal(p.id, items: nil) : try await env.api.declineProposal(p.id)
            return nil
        }
    }
}

/// One line of the feed: what, by whom, when.
struct ActivityRow: View {
    let item: ActivityItem
    let agent: Agent
    let showsAgent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ActivityRow.symbol(item.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.kind == "failed" ? Color.red : agent.tint)
                .frame(width: 28, height: 28)
                .background(agent.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(heading).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 4)
                    if let date = item.date {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail.markdown).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(item.kind == "quiet" || item.kind == "cancelled" ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    /// "Coach · Added a reminder", or just the title in one agent's own feed.
    private var heading: String {
        let what = ActivityRow.verb(item.kind).map { "\($0) \(item.title)" } ?? item.title
        return showsAgent ? "\(agent.name) · \(what)" : what
    }

    /// Words before the title where the title alone wouldn't say what happened.
    static func verb(_ kind: String) -> String? {
        switch kind {
        case "queued": "Asked to"
        case "confirmed": "Done:"
        case "failed": "Failed:"
        case "cancelled": "Cancelled:"
        default: nil
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "action", "confirmed": "checkmark"
        case "queued": "hourglass"
        case "failed": "exclamationmark.triangle"
        case "cancelled": "xmark"
        case "routine": "alarm"
        case "watch", "quiet": "eye"
        case "ask": "bubble.left.and.bubble.right"
        case "message": "text.bubble"
        case "objectives": "scope"
        case "drafts": "square.and.pencil"
        case "digest": "sun.horizon"
        default: "circle.fill"
        }
    }
}

/// A queued action with its own Confirm and Cancel.
private struct QueuedActionRow: View {
    let action: QueuedAction
    let agent: Agent
    let busy: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: agent, size: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.purchase?.summary ?? action.summary)
                    if let expires = action.expiresAt.flatMap(Wire.parse) {
                        Text("\(agent.name) · expires \(expires.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let order = action.purchase { PurchaseSummary(detail: order) }
            HStack(spacing: 10) {
                Button(action: confirm) {
                    Text(action.purchase.map { _ in "Review and confirm" } ?? "Confirm").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button(role: .cancel, action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}

/// A notebook proposal: what Professor would write, applied or put off from here.
private struct ProposalRow: View {
    let proposal: NotebookProposal
    let agent: Agent
    let busy: Bool
    let apply: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: agent, size: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.kind == "outline" ? "A notebook outline" : "Notebook changes")
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            HStack(spacing: 10) {
                Button(action: apply) { Text("Apply").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button(action: decline) { Text("Not now").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let items = proposal.items ?? []
        let topics = items.count == 1 ? "1 topic" : "\(items.count) topics"
        let titles = items.prefix(3).map(\.title).joined(separator: ", ") + (items.count > 3 ? "…" : "")
        return [proposal.courseName, topics, titles.isEmpty ? nil : titles].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The feed's days and times, in words.
enum ActivityDays {
    struct Group { let day: Date; let items: [ActivityItem] }

    /// Newest day first, each day's items as they came (newest first).
    static func group(_ items: [ActivityItem], calendar: Calendar = .current) -> [Group] {
        var days: [Date] = []
        var byDay: [Date: [ActivityItem]] = [:]
        for item in items {
            guard let date = item.date else { continue }
            let day = calendar.startOfDay(for: date)
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(item)
        }
        return days.map { Group(day: $0, items: byDay[$0] ?? []) }
    }

    /// "Today", "Yesterday", else "Monday 19 October".
    static func title(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "18:30" today, "Tomorrow 09:00", else "Sun 18:00".
    static func upcoming(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
