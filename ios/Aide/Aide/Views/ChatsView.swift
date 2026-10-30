import SwiftUI

/// The Team tab, the app's home: a greeting with the latest briefing's note (tap: the briefing) and chips for the day
/// (habits, what's waiting; each opens Today), over a glow in Aide's colour. Then Aide, pinned with a box to write in,
/// and a card of rows: the team's group chat first, then each specialist with the last line of its latest chat.
/// Tapping a row carries on that chat (or starts one); long-press for a new chat, past chats, routines, activity or
/// its profile. A chat opens on top. Only conversations: digests, routines' and watches' posts and what's waiting for
/// you are on Today.
struct ChatsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var digest: DigestViewModel
    @State private var pastChats: Agent?
    @State private var routinesFor: Agent?
    @State private var infoFor: Agent?
    /// Picked in Past chats; run once the sheet is gone, so the push isn't lost in its dismissal.
    @State private var choice: PastChatsSheet.Choice?
    @State private var showTeam = false
    /// Picked with "Open chat" in the team chat; opened once that screen is gone.
    @State private var openAfterTeam: String?
    /// An agent's Activity sheet.
    @State private var activity: ActivityScope?
    /// Picked in the Activity sheet; opened once it's gone.
    @State private var openAfterActivity: String?
    /// Picked on an agent's profile; run once the sheet is gone.
    @State private var infoAction: (Agent, AgentInfoSheet.Action)?
    /// Things waiting for your OK, for the tab's badge.
    @Binding var waiting: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if settings.isConfigured {
                        Greeting(waiting: $waiting)
                    } else {
                        TopBlock("Your team") {
                            Text("Add your server token in Settings to start.").foregroundStyle(.secondary)
                        }
                    }
                    AideCard(agent: chat.orchestrator, latest: chat.chats(with: chat.orchestrator).first,
                             working: chat.working(for: chat.orchestrator), mood: mood(chat.orchestrator),
                             loading: loading,
                             open: { Task { await chat.talk(to: chat.orchestrator) } },
                             write: { Task { chat.typeOnOpen = true; await chat.startChat(with: chat.orchestrator) } },
                             talk: { Task { await chat.startChat(with: chat.orchestrator); await env.voice.toggle() } })
                        .disabled(!settings.isConfigured)
                        .contextMenu { menu(chat.orchestrator) }
                    VStack(spacing: 0) {
                        TeamRow(agents: chat.agents, latest: chat.team.last,
                                name: { $0 == "user" ? "You" : chat.agent($0).name }) { showTeam = true }
                            .disabled(!settings.isConfigured)
                        if chat.agentsLoaded || !settings.isConfigured {
                            ForEach(chat.agents.filter { !$0.orchestrator }) { agent in
                                RowDivider(leading: 72)
                                row(agent)
                            }
                        } else {
                            ForEach(0..<4, id: \.self) { _ in RowDivider(leading: 72); AgentRowPlaceholder() }
                        }
                    }
                    .card(padding: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .pageGlow(settings.isConfigured ? Theme.accent : nil)
            // Its own header rather than a navigation bar: the chats hide the bar, and a bar coming back as a
            // chat closes appears all at once instead of sliding in with the page.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $chat.isChatOpen) { ChatView() }
            .navigationDestination(isPresented: $showTeam) {
                TeamChatView { id in openAfterTeam = id; showTeam = false }
            }
            .sheet(item: $pastChats, onDismiss: runChoice) { agent in
                PastChatsSheet(agent: agent) { choice = $0; pastChats = nil }
            }
            .sheet(item: $routinesFor, onDismiss: runChoice) { agent in
                RoutinesSheet(agent: agent) { choice = $0; routinesFor = nil }
            }
            .sheet(item: $infoFor, onDismiss: runInfoAction) { agent in
                AgentInfoSheet(agent: agent) { infoAction = (agent, $0); infoFor = nil }
            }
            .sheet(item: $activity, onDismiss: afterActivity) { scope in
                ActivitySheet(agent: scope.agent) { id in openAfterActivity = id; activity = nil }
            }
            .refreshable { await load() }
            .task {
                await load()
                #if DEBUG
                await openForPreview()
                #endif
            }
            // Back from a chat: its preview may have changed.
            .onChange(of: chat.isChatOpen) { _, open in if !open { Task { await load() } } }
            .onChange(of: env.showTeam, initial: true) { _, show in
                guard show else { return }
                env.showTeam = false
                chat.isChatOpen = false
                showTeam = true
            }
            .onChange(of: showTeam) { _, shown in
                guard !shown, let id = openAfterTeam else { return }
                openAfterTeam = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(450)) // let the team chat slide away first
                    await chat.open(id: id)
                }
            }
        }
    }

    private var loading: Bool { settings.isConfigured && !chat.conversationsLoaded }

    private func mood(_ agent: Agent) -> String {
        !settings.isConfigured ? "sleeping" : chat.working(for: agent) != nil ? "thinking" : "awake"
    }

    private func row(_ agent: Agent) -> some View {
        AgentRow(agent: agent, latest: chat.chats(with: agent).first, working: chat.working(for: agent),
                 mood: mood(agent), loading: loading) {
            Task { await chat.talk(to: agent) }
        }
        .disabled(!settings.isConfigured)
        .contextMenu { menu(agent) }
    }

    @ViewBuilder private func menu(_ agent: Agent) -> some View {
        Button("New chat", systemImage: "square.and.pencil") { Task { await chat.startChat(with: agent) } }
        Button("Past chats", systemImage: "clock") { pastChats = agent }
        Button("Routines", systemImage: "alarm") { routinesFor = agent }
        Button("Activity", systemImage: "list.bullet.rectangle") { activity = .agent(agent) }
        Button("About \(agent.name)", systemImage: "info.circle") { infoFor = agent }
    }

    /// A button on an agent's profile, once the sheet is gone.
    private func runInfoAction() {
        guard let (agent, action) = infoAction else { return }
        infoAction = nil
        switch action {
        case .newChat: Task { await chat.startChat(with: agent) }
        case .starter(let text): Task { await chat.startChat(with: agent); await chat.send(text) }
        case .pastChats: pastChats = agent
        case .routines: routinesFor = agent
        case .activity: activity = .agent(agent)
        case .thinkHarder, .quiz, .practiceExam: break // only in a chat
        }
    }

    private func load() async {
        async let agents: Void = chat.loadAgents()
        async let team: Void = chat.loadTeam()
        async let routines: Void = chat.loadRoutines()
        await chat.loadConversations()
        await agents
        await team
        await routines
    }

    /// A line tapped in the Activity sheet: its chat. "team" is the team chat, "main" the old shared chat, which the
    /// app shows as Aide's latest.
    private func afterActivity() {
        guard let id = openAfterActivity else { return }
        openAfterActivity = nil
        switch id {
        case "team": showTeam = true
        case "main": Task { await chat.talk(to: chat.orchestrator) }
        default: Task { await chat.open(id: id) }
        }
    }

    #if DEBUG
    /// Simulator screenshots: `-previewOpen team` opens the Team chat, `-previewOpen coach` Coach's latest chat,
    /// `-previewOpen new:coach` a blank one (nothing is sent until you write), `-previewOpen files:f_1,f_2` a Moodle
    /// notification's files.
    private func openForPreview() async {
        // On the phone, launched over the cable with `-voiceTest YES`: a voice chat with Aide, to try voice from the Mac.
        if UserDefaults.standard.bool(forKey: "voiceTest") {
            await chat.newChat(with: chat.orchestrator)
            await env.voice.toggle()
            return
        }
        guard settings.isPreview, let target = UserDefaults.standard.string(forKey: "previewOpen") else { return }
        if target == "team" { showTeam = true; return }
        if target.hasPrefix("errand:"), let id = Int(target.dropFirst(7)) { env.browser = .errand(id, title: "Errand"); return }
        if target.hasPrefix("chat:") { await chat.open(id: String(target.dropFirst(5))); return }
        if target.hasPrefix("files:") { env.newFiles = NewFiles(ids: target.dropFirst(6).split(separator: ",").map(String.init)); return }
        if target.hasPrefix("info:") { infoFor = chat.agent(String(target.dropFirst(5))); return }
        if target.hasPrefix("new:") { await chat.newChat(with: chat.agent(String(target.dropFirst(4)))); return }
        if target == "voice" { await chat.newChat(with: chat.orchestrator); await env.voice.toggle(); return }
        await chat.talk(to: chat.agent(target))
    }
    #endif

    private func runChoice() {
        guard let picked = choice else { return }
        choice = nil
        Task { await chat.run(picked) }
    }
}

/// Aide, pinned above the team: the last line of its latest chat (tap: carry on), and a box to write in that opens a
/// new chat with the keyboard up, or with voice from the mic.
private struct AideCard: View {
    let agent: Agent
    let latest: Conversation?
    var working: String?
    let mood: String
    var loading = false
    let open: () -> Void
    let write: () -> Void
    let talk: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    LivePebble(mood: mood, size: 52, figure: agent.figure)
                        .foregroundStyle(agent.tint)
                        .allowsHitTesting(false)
                    AgentText(agent: agent, latest: latest, working: working, loading: loading, lines: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPress())
            .accessibilityHint(latest == nil ? "Starts a chat" : "Opens your latest chat")
            HStack(spacing: 8) {
                Button(action: write) {
                    Text("Ask \(agent.name) anything")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Starts a new chat")
                Button(action: talk) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to \(agent.name)")
            }
            .background(Theme.chip, in: Capsule())
        }
        .card()
    }
}

/// The name, when, and the last line of an agent's latest chat (what it does, before you've talked; what it's doing
/// while it answers in a chat you left).
private struct AgentText: View {
    let agent: Agent
    let latest: Conversation?
    var working: String?
    var loading = false
    var lines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.name).font(.headline).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let date = latest?.updatedAt.flatMap(Wire.parse) {
                    Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if loading {
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBar(height: 11)
                    if lines > 1 { SkeletonBar(width: 150, height: 11) }
                }
                .padding(.vertical, 3)
                .shimmering()
            } else {
                Text(working ?? preview)
                    .font(.subheadline)
                    .foregroundStyle(working == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(agent.tint))
                    .lineLimit(lines, reservesSpace: lines > 1)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: String {
        if let preview = latest?.preview, !preview.isEmpty { return preview }
        return agent.role.isEmpty ? "Say hi" : agent.role
    }
}

/// One specialist, a row in the team's card.
private struct AgentRow: View {
    let agent: Agent
    let latest: Conversation?
    var working: String?
    let mood: String
    var loading = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                LivePebble(mood: mood, size: 44, figure: agent.figure)
                    .foregroundStyle(agent.tint)
                    .allowsHitTesting(false)
                AgentText(agent: agent, latest: latest, working: working, loading: loading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint(latest == nil ? "Starts a chat" : "Opens your latest chat")
    }
}

/// A specialist's row while the team is on its way: the same size, grey shapes for the figure and the words.
private struct AgentRowPlaceholder: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Color.secondary.opacity(0.16)).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 80, height: 14)
                SkeletonBar(height: 11)
                SkeletonBar(width: 150, height: 11)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// The way into the team's group chat, the first row: everyone stacked, with the latest message.
private struct TeamRow: View {
    let agents: [Agent]
    let latest: TeamMessage?
    let name: (String) -> String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: -14) {
                    ForEach(agents) { agent in
                        PebbleMark(size: 22, figure: agent.figure).foregroundStyle(agent.tint)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Team chat").font(.headline).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if let date = latest?.ts.flatMap(Wire.parse) {
                            Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Text(latest.map { "\(name($0.from)): \($0.text)" } ?? "Talk to all of them at once")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the team chat")
    }
}

/// One agent's chats, newest first, with a new chat on top. Swipe to delete.
struct PastChatsSheet: View {
    enum Choice { case new(Agent), open(Conversation), openID(String) }

    @EnvironmentObject private var chat: ChatViewModel
    let agent: Agent
    let choose: (Choice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { choose(.new(agent)) } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .foregroundStyle(agent.tint)
                }
                .listRowBackground(Theme.row)
                Section {
                    let chats = chat.chats(with: agent)
                    if chats.isEmpty {
                        Text("No chats with \(agent.name) yet.").foregroundStyle(.secondary)
                    }
                    ForEach(chats) { c in
                        Button { choose(.open(c)) } label: { ConversationRow(conversation: c) }
                            .listRowBackground(c.id == chat.conversationID ? Theme.chip : Theme.row)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { chats[$0] }
                        Task { for c in doomed { await chat.delete(c) } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.grouped)
    }
}

extension ChatViewModel {
    func run(_ choice: PastChatsSheet.Choice) async {
        switch choice {
        case .new(let agent): await startChat(with: agent)
        case .open(let conversation): await open(conversation)
        case .openID(let id): await open(id: id)
        }
    }
}

/// One chat: the title, when it was last used, and a preview.
struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                if conversation.routine != nil {
                    Image(systemName: "alarm").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Routine")
                }
                Text(conversation.title ?? "New chat")
                    .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                if let date = conversation.updatedAt.flatMap(Wire.parse) {
                    Text(Self.when(date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let preview = conversation.preview, !preview.isEmpty {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// 14:05 today, "Yesterday", the weekday this week, else the date.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The top of the Team tab: the time of day, the latest briefing's note in full (tap: its Details), and chips for how
/// many habits are done today and what's waiting for your OK; each chip opens Today there.
private struct Greeting: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var waiting: Int
    @State private var habits: [Habit]?

    var body: some View {
        TimelineView(.everyMinute) { context in
            TopBlock(Self.title(at: context.date),
                     overline: context.date.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                briefing
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: habitsLine, systemImage: "checkmark.circle.fill", iconColor: .green) { open(.habits) }
                        if waiting > 0 {
                            Chip(title: "\(waiting) waiting", systemImage: "tray.full.fill", style: .prominent) { open(.top) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
                .padding(.top, 2)
            }
        }
        .task { await load() }
        .onChange(of: env.showToday) { _, shown in if !shown { Task { await load() } } } // ticked something there
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    @ViewBuilder private var briefing: some View {
        if let latest = digest.latest {
            Button { digest.showLatest() } label: {
                Text(latest.greeting.markdown)
                    .font(.body)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CardPress())
            .accessibilityHint("Opens the briefing")
        } else if !digest.latestLoaded {
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(height: 14)
                SkeletonBar(height: 14)
                SkeletonBar(width: 180, height: 14)
            }
            .shimmering()
        }
    }

    static func title(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// "3 of 5 habits". Counted habits (a daily limit) aren't in it: they're never "done" during the day.
    private var habitsLine: String {
        guard let habits else { return "Habits" }
        let ticked = habits.filter { !$0.isLimit }
        guard !ticked.isEmpty else { return habits.isEmpty ? "No habits yet" : "Habits" }
        let done = ticked.filter { $0.doneToday || ($0.isWeekly && $0.thisWeek >= ($0.cadence.perWeek ?? 1)) }.count
        return done == ticked.count ? "All \(ticked.count) habits" : "\(done) of \(ticked.count) habits"
    }

    private func open(_ focus: TodayFocus) {
        env.todayFocus = focus
        env.showToday = true
    }

    private func load() async {
        async let latest: Void = digest.loadLatest()
        async let approvals = try? env.api.approvals()
        habits = (try? await env.api.habits()) ?? habits
        if let a = await approvals { waiting = a.waiting }
        await latest
    }
}
