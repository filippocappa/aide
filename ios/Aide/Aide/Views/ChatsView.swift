import SwiftUI

/// The Team tab, the app's home: the briefing behind the sun in the corner, a strip for the day (habits, what's
/// waiting; the Today page from it),
/// then your team. Aide on a wide card on top, the specialists two by two below, each alive in its own
/// colour with the last line of its latest chat. Tapping a card carries on that chat (or starts one); long-press
/// for a new chat or past chats. A chat opens on top. Below them, the team's own group chat. Only conversations:
/// digests, routines' and watches' posts and what's waiting for you are on Today.
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
    /// Things waiting for your OK, for the tab's badge.
    @Binding var waiting: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if settings.isConfigured { TodayStrip(waiting: $waiting) }
                    if !settings.isConfigured {
                        Text("Add your server token in Settings to start.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    card(chat.orchestrator, wide: true)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        if chat.agentsLoaded || !settings.isConfigured {
                            ForEach(chat.agents.filter { !$0.orchestrator }) { card($0, wide: false) }
                        } else {
                            ForEach(0..<4, id: \.self) { _ in AgentCardPlaceholder() }
                        }
                    }
                    TeamCard(agents: chat.agents, latest: chat.team.last,
                             name: { $0 == "user" ? "You" : chat.agent($0).name }) { showTeam = true }
                        .disabled(!settings.isConfigured)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Theme.background)
            // Its own header rather than a navigation bar: the chats hide the bar, and a bar coming back as a
            // chat closes appears all at once instead of sliding in with the page.
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) { // the status bar over a solid strip, not over scrolling cards
                Theme.background.frame(height: 0).ignoresSafeArea(edges: .top)
            }
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
            .sheet(item: $infoFor) { AgentInfoSheet(agent: $0) }
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

    private var header: some View {
        HStack {
            Text("Your team").font(.largeTitle.bold())
            Spacer()
            Button { digest.showLatest() } label: { HeaderIcon(name: "sun.horizon") }
                .buttonStyle(.plain)
                .accessibilityLabel("Briefing")
                .disabled(!settings.isConfigured)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func card(_ agent: Agent, wide: Bool) -> some View {
        AgentCard(agent: agent, latest: chat.chats(with: agent).first, wide: wide,
                  mood: settings.isConfigured ? "awake" : "sleeping",
                  loading: settings.isConfigured && !chat.conversationsLoaded) {
            Task { await chat.talk(to: agent) }
        }
        .disabled(!settings.isConfigured)
        .contextMenu {
            Button("New chat", systemImage: "square.and.pencil") { Task { await chat.startChat(with: agent) } }
            Button("Past chats", systemImage: "clock") { pastChats = agent }
            Button("Routines", systemImage: "alarm") { routinesFor = agent }
            Button("Activity", systemImage: "list.bullet.rectangle") { activity = .agent(agent) }
            Button("About \(agent.name)", systemImage: "info.circle") { infoFor = agent }
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

/// One teammate: alive in its colour on a plain card, with the last line of its latest chat (or what it does,
/// before you've talked).
private struct AgentCard: View {
    let agent: Agent
    let latest: Conversation?
    let wide: Bool
    let mood: String
    /// The chats are on their way: placeholder lines instead of the role.
    var loading = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Group {
                if wide {
                    HStack(spacing: 14) {
                        figure(60)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) { name; Spacer(minLength: 4); time }
                            line(2)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) { figure(44); Spacer(minLength: 4); time }
                        VStack(alignment: .leading, spacing: 3) { name; line(2) }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 128, alignment: .top)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint(latest == nil ? "Starts a chat" : "Opens your latest chat")
    }

    private func figure(_ size: CGFloat) -> some View {
        LivePebble(mood: mood, size: size, figure: agent.figure)
            .foregroundStyle(agent.tint)
            .allowsHitTesting(false)
    }

    private var name: some View {
        Text(agent.name).font(.headline)
    }

    @ViewBuilder private var time: some View {
        if let date = latest?.updatedAt.flatMap(Wire.parse) {
            Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func line(_ lines: Int) -> some View {
        if loading {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(height: 11)
                SkeletonBar(width: wide ? 150 : 70, height: 11)
            }
            .padding(.vertical, 3)
            .shimmering()
        } else {
            previewText(lines)
        }
    }

    private func previewText(_ lines: Int) -> some View {
        Text(preview)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(lines, reservesSpace: true)
            .multilineTextAlignment(.leading)
    }

    private var preview: String {
        if let preview = latest?.preview, !preview.isEmpty { return preview }
        return agent.role.isEmpty ? "Say hi" : agent.role
    }
}

/// A specialist's card while the team is on its way: the same size, grey shapes for the figure and the words.
private struct AgentCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Circle().fill(Color.secondary.opacity(0.16)).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 80, height: 14)
                SkeletonBar(height: 11)
                SkeletonBar(width: 70, height: 11)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 128, alignment: .top)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// The way into the team's group chat: everyone together, with the latest message.
private struct TeamCard: View {
    let agents: [Agent]
    let latest: TeamMessage?
    let name: (String) -> String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                HStack(spacing: -10) {
                    ForEach(agents) { agent in
                        LivePebble(mood: "calm", size: 30, figure: agent.figure)
                            .foregroundStyle(agent.tint)
                            .allowsHitTesting(false)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Team chat").font(.headline)
                        Spacer(minLength: 4)
                        if let date = latest?.ts.flatMap(Wire.parse) {
                            Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Text(latest.map { "\(name($0.from)): \($0.text)" } ?? "Talk to all of them at once")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the team chat")
    }
}

/// Cards give a little under the finger, without bouncing back.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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

/// The day on top of the team: how many habits are done today and what's waiting for your OK; each opens Today.
private struct TodayStrip: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var waiting: Int
    @State private var habits: [Habit]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "checkmark.circle.fill", color: .green) {
                Text(habitsLine)
            } action: { open(.habits) }
            if waiting > 0 {
                Divider().padding(.leading, 40)
                row(icon: "tray.full.fill", color: .orange) {
                    Text("\(waiting) waiting for you")
                } action: { open(.top) }
            }
        }
        .font(.subheadline)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { await load() }
        .onChange(of: env.showToday) { _, shown in if !shown { Task { await load() } } } // ticked something there
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    private func row(icon: String, color: Color, @ViewBuilder text: () -> some View,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 20)
                text().foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "3 of 5 habits done today". Counted habits (a daily limit) aren't in it: they're never "done" during the day.
    private var habitsLine: String {
        guard let habits else { return "Habits" }
        let ticked = habits.filter { !$0.isLimit }
        guard !ticked.isEmpty else { return habits.isEmpty ? "No habits yet" : "Habits" }
        let done = ticked.filter { $0.doneToday || ($0.isWeekly && $0.thisWeek >= ($0.cadence.perWeek ?? 1)) }.count
        return done == ticked.count ? "All \(ticked.count) habits done today" : "\(done) of \(ticked.count) habits done today"
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
