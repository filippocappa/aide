import SwiftUI

/// The Chats tab: your team. Aide on a wide card on top, the specialists two by two below, each alive in its own
/// colour with the last line of its latest chat. Tapping a card carries on that chat (or starts one); long-press
/// for a new chat or past chats. A chat opens on top. Below them, the team's own group chat.
struct ChatsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digest: DigestViewModel
    @EnvironmentObject private var env: AppEnvironment
    @State private var pastChats: Agent?
    @State private var routinesFor: Agent?
    @State private var infoFor: Agent?
    /// Picked in Past chats; run once the sheet is gone, so the push isn't lost in its dismissal.
    @State private var choice: PastChatsSheet.Choice?
    @State private var showTeam = false
    @State private var showObjectives = false
    @State private var objectives: ObjectivesOverview?
    /// Picked with "Open chat" in the team chat; opened once that screen is gone.
    @State private var openAfterTeam: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if !settings.isConfigured {
                        Text("Add your server token in Settings to start.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    card(chat.orchestrator, wide: true)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(chat.agents.filter { !$0.orchestrator }) { card($0, wide: false) }
                    }
                    ObjectivesCard(overview: objectives) { showObjectives = true }
                        .disabled(!settings.isConfigured)
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
            .navigationDestination(isPresented: $showObjectives) { ObjectivesView() }
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
            .refreshable { await load() }
            .task {
                await load()
                #if DEBUG
                await openForPreview()
                #endif
            }
            // Back from a chat: its preview may have changed.
            .onChange(of: chat.isChatOpen) { _, open in if !open { Task { await load() } } }
            .onChange(of: showObjectives) { _, shown in
                if !shown { Task { objectives = try? await env.api.objectives() } }
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
        .sheet(isPresented: $digest.isPresented) { DigestSheet() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Your team").font(.largeTitle.bold())
            Spacer()
            Button {
                digest.kind = DigestViewModel.Kind(rawValue: ChatViewModel.digestKind()) ?? .daily
                digest.isPresented = true
            } label: { HeaderIcon(name: "sun.horizon") }
                .buttonStyle(.plain)
                .accessibilityLabel("Digest")
                .disabled(!settings.isConfigured)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func card(_ agent: Agent, wide: Bool) -> some View {
        AgentCard(agent: agent, latest: chat.chats(with: agent).first, wide: wide, mood: settings.isConfigured ? "awake" : "sleeping") {
            Task { await chat.talk(to: agent) }
        }
        .disabled(!settings.isConfigured)
        .contextMenu {
            Button("New chat", systemImage: "square.and.pencil") { Task { await chat.startChat(with: agent) } }
            Button("Past chats", systemImage: "clock") { pastChats = agent }
            Button("Routines", systemImage: "alarm") { routinesFor = agent }
            Button("About \(agent.name)", systemImage: "info.circle") { infoFor = agent }
        }
    }

    private func load() async {
        async let agents: Void = chat.loadAgents()
        async let team: Void = chat.loadTeam()
        async let routines: Void = chat.loadRoutines()
        async let objectives = try? env.api.objectives()
        await chat.loadConversations()
        self.objectives = await objectives
        await agents
        await team
        await routines
    }

    #if DEBUG
    /// Simulator screenshots: `-previewOpen team` opens the Team chat, `-previewOpen coach` Coach's latest chat,
    /// `-previewOpen new:coach` a blank one (nothing is sent until you write).
    private func openForPreview() async {
        // On the phone, launched over the cable with `-voiceTest YES`: a voice chat with Aide, to try voice from the Mac.
        if UserDefaults.standard.bool(forKey: "voiceTest") {
            await chat.newChat(with: chat.orchestrator)
            await env.voice.toggle()
            return
        }
        guard settings.isPreview, let target = UserDefaults.standard.string(forKey: "previewOpen") else { return }
        if target == "team" { showTeam = true; return }
        if target == "objectives" { showObjectives = true; return }
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

    private func line(_ lines: Int) -> some View {
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
private struct CardPress: ButtonStyle {
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
