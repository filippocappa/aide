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
/// approvals"). Chips for whose, then what's waiting for your OK (`WaitingSection`; left out from Today, which shows
/// it itself), the routines coming up, then what was done by day, grouped by the server (a run of meals, an errand,
/// a plan is one row that folds open; a day's quiet checks one grey line). Opened from Today's "All activity" for
/// everyone, or from an agent's card for that agent alone.
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
    /// The grouped rows opened to show their lines.
    @State private var unfolded: Set<Int> = []
    /// The earlier days opened (the newest day is always open).
    @State private var openDays: Set<Date> = []
    /// False on Today, which shows what's waiting above its own link here.
    var showsWaiting = true

    var body: some View {
        NavigationStack {
            page
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(agent.map { "\($0.name)'s activity" } ?? "Activity")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: agent?.id) { await load() }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.grouped)
    }

    /// The phone: one list. The Mac: the feed, with what's waiting and what's coming up beside it.
    @ViewBuilder private var page: some View {
        #if os(macOS)
        MacSplitList(sideWidth: 380) {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section { chips }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            feed
        } side: {
            if showsWaiting {
                WaitingSection(approvals: approvals, agent: agent, reload: { await load() }, open: go)
            }
            upcomingSection
            if loaded, (approvals?.waiting ?? 0) == 0 || !showsWaiting,
               (approvals?.upcoming ?? []).filter(mine(\.agent)).isEmpty {
                Section { Text("Nothing waiting for you, and nothing planned.").foregroundStyle(.secondary) }
                    .listRowBackground(Theme.row)
            }
        }
        #else
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section { chips }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            if showsWaiting {
                WaitingSection(approvals: approvals, agent: agent, reload: { await load() }, open: go)
            }
            upcomingSection
            feed
        }
        #endif
    }

    /// The days, the newest open, the earlier ones folded.
    @ViewBuilder private var feed: some View {
                let days = ActivityDays.group(items)
                ForEach(days, id: \.day) { group in
                    if group.day == days.first?.day {
                        Section(ActivityDays.title(group.day)) {
                            ForEach(group.items) { item in rows(item) }
                        }
                    } else {
                        Section { day(group) }
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

    /// Everyone, then each agent: whose activity the sheet shows.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Everyone", tint: Theme.accent, on: agent == nil) { agent = nil }
                ForEach(chat.agents) { a in
                    chip(a.name, tint: a.tint, on: agent?.id == a.id) { agent = a }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.black.opacity(0.85) : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(on ? tint : Theme.row, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An earlier day, folded to one row ("Yesterday · 14 things from Coach, Aide and Secretary"); a tap opens its
    /// rows under it.
    @ViewBuilder private func day(_ group: ActivityDays.Group) -> some View {
        let open = openDays.contains(group.day)
        Button {
            withAnimation(.snappy) { if open { openDays.remove(group.day) } else { openDays.insert(group.day) } }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityDays.title(group.day)).font(.headline).foregroundStyle(.primary)
                    Text(ActivityDays.summary(group, names: { chat.agent($0).name }))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .contentShape(Rectangle())
            .multilineTextAlignment(.leading)
        }
        .listRowBackground(Theme.row)
        .accessibilityHint(open ? "Folds the day" : "Shows the day")
        if open {
            ForEach(group.items) { item in rows(item) }
        }
    }

    /// A row, and its lines under it while it's open. A row that folds lines opens on a tap; a line opens its chat.
    @ViewBuilder private func rows(_ item: ActivityItem) -> some View {
        let open = unfolded.contains(item.id)
        Button {
            if item.children != nil {
                withAnimation(.snappy) { if open { unfolded.remove(item.id) } else { unfolded.insert(item.id) } }
            } else {
                go(item.conversationId)
            }
        } label: {
            ActivityRow(item: item, agent: chat.agent(item.agent), showsAgent: agent == nil,
                        names: (item.agents ?? []).map { chat.agent($0).name }, unfolded: open)
                .multilineTextAlignment(.leading) // the Mac centres a button's lines
        }
        .disabled(item.children == nil && item.conversationId == nil)
        .listRowBackground(Theme.row)
        if open {
            ForEach(item.children ?? []) { line in
                Button { go(line.conversationId) } label: {
                    ActivityLine(item: line, agent: chat.agent(line.agent), showsAgent: (item.agents?.count ?? 1) > 1)
                        .multilineTextAlignment(.leading)
                }
                .disabled(line.conversationId == nil)
                .listRowBackground(Theme.row)
            }
        }
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
        async let page = env.api.activity(agent: agent?.id, grouped: true)
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
            let page = try await env.api.activity(agent: agent?.id, before: before, grouped: true)
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
        // A server with plans: each period's proposals as one card. An older one: a row each.
        let plans = approvals?.plans.map { plans in
            plans.map { p in var p = p; p.objectives = p.objectives.filter(mine(\.agent)); return p }
                .filter { !$0.objectives.isEmpty }
        }
        let rows = plans == nil ? objectives : []
        let proposals = agent == nil || agent?.id == "professor" ? approvals?.proposals ?? [] : []
        let writer = agent == nil || agent?.id == "professor" ? approvals?.writer : nil
        let errands = agent == nil || agent?.id == "aide" ? approvals?.errands ?? [] : []
        // Orders are confirmed one at a time, from their own page.
        let plain = actions.filter { !$0.reviewed }
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
                                        if action.reviewed { reviewing = action } else { Task { await decide(action, confirm: true) } }
                                    },
                                    cancel: { Task { await decide(action, confirm: false) } })
                        .contentShape(Rectangle())
                        .onTapGesture { if action.reviewed { reviewing = action } else { go(action.conversationId) } }
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
                ForEach(plans ?? [], id: \.period) { plan in
                    ObjectivePlanCard(plan: plan) { await load() }
                        .listRowBackground(Theme.row)
                }
                ForEach(rows) { o in
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
                if !rows.isEmpty {
                    Button { Task { await accept(rows) } } label: {
                        Label(rows.count == 1 ? "Accept the objective" : "Accept all \(rows.count) objectives",
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
                if !rows.isEmpty { Text("Swipe an objective to accept or drop it on its own.") }
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

/// One row of the feed: what, by whom, when. A grouped row says how many lines it folds and has a chevron; a day's
/// quiet checks are one small grey line.
struct ActivityRow: View {
    let item: ActivityItem
    let agent: Agent
    let showsAgent: Bool
    /// Who, for a grouped row of more than one agent.
    var names: [String] = []
    var unfolded = false

    var body: some View {
        if item.kind == "quiet" { quiet } else { full }
    }

    private var quiet: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").font(.caption).foregroundStyle(.tertiary).frame(width: 28)
            Text([item.title, item.detail].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(unfolded ? nil : 1)
            Spacer(minLength: 4)
            if item.children != nil { chevron }
        }
        .accessibilityElement(children: .combine)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(unfolded ? 180 : 0))
    }

    private var full: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ActivityRow.symbol(item.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.kind == "failed" ? Color.red : agent.tint)
                .frame(width: 28, height: 28)
                .background(agent.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(heading).foregroundStyle(.primary).lineLimit(2)
                    if let count = item.count, count > 1, item.kind != "objectives" {
                        Text("×\(count)").font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(agent.tint)
                    }
                    Spacer(minLength: 4)
                    if let date = item.date {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }
                    if item.children != nil { chevron }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail.markdown).font(.subheadline).foregroundStyle(.secondary).lineLimit(unfolded ? 1 : 3)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(item.kind == "cancelled" ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    /// "Coach · Added a reminder", "Coach and Professor · Proposed 9 objectives", or just the title in one agent's feed.
    private var heading: String {
        let what = ActivityRow.verb(item.kind).map { "\($0) \(item.title)" } ?? item.title
        guard showsAgent else { return what }
        let who = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : agent.name
        return "\(who) · \(what)"
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
        case "errand": "safari"
        default: "circle.fill"
        }
    }
}

/// One of a grouped row's lines, small, under it: the time, what (when it's not the row's own title) and its detail.
struct ActivityLine: View {
    let item: ActivityItem
    let agent: Agent
    let showsAgent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.date?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(showsAgent ? "\(agent.name) · \(item.title)" : item.title)
                    .font(.footnote.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail.markdown).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
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
                    Text(action.detail?.summary ?? action.summary)
                    if let expires = action.expiresAt.flatMap(Wire.parse) {
                        Text("\(agent.name) · expires \(expires.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let order = action.purchase, order.hasSummary { PurchaseSummary(detail: order) }
            if let drop = action.drop { DropSummary(detail: drop) }
            HStack(spacing: 10) {
                Button(action: confirm) {
                    Text(action.reviewed ? "Review and confirm" : "Confirm").frame(maxWidth: .infinity)
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

    /// "14 things from Coach, Aide and Secretary": every line the day's rows fold, and who, most first.
    static func summary(_ group: Group, names: (String) -> String) -> String {
        var lines = 0
        var byAgent: [String: Int] = [:]
        for item in group.items {
            let n = item.count ?? 1
            lines += n
            for a in item.agents ?? [item.agent] { byAgent[a, default: 0] += n }
        }
        let who = byAgent.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { names($0.key) }
        let list = who.count <= 1 ? (who.first ?? "") : who.dropLast().joined(separator: ", ") + " and " + who.last!
        let things = lines == 1 ? "1 thing" : "\(lines) things"
        return list.isEmpty ? things : "\(things) from \(list)"
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
