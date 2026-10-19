import SwiftUI

/// The Chats tab: your team. Aide on a wide card on top, the specialists two by two below, each alive in its own
/// colour with the last line of its latest chat. Tapping a card carries on that chat (or starts one); long-press
/// for a new chat or past chats. A chat opens on top. Below them, the team's own group chat.
struct ChatsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digest: DigestViewModel
    @State private var pastChats: Agent?
    @State private var routinesFor: Agent?
    /// Picked in Past chats; run once the sheet is gone, so the push isn't lost in its dismissal.
    @State private var choice: PastChatsSheet.Choice?
    @State private var showTeam = false
    /// Picked with "Open chat" in the team chat; opened once that screen is gone.
    @State private var openAfterTeam: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
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
                    TeamCard(agents: chat.agents, latest: chat.team.last,
                             name: { $0 == "user" ? "You" : chat.agent($0).name }) { showTeam = true }
                        .disabled(!settings.isConfigured)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Theme.background)
            .navigationTitle("Your team")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        digest.kind = DigestViewModel.Kind(rawValue: ChatViewModel.digestKind()) ?? .daily
                        digest.isPresented = true
                    } label: { Image(systemName: "sun.horizon") }
                        .accessibilityLabel("Digest")
                        .disabled(!settings.isConfigured)
                }
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
            .refreshable { await load() }
            .task { await load() }
            // Back from a chat: its preview may have changed.
            .onChange(of: chat.isChatOpen) { _, open in if !open { Task { await load() } } }
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

    private func card(_ agent: Agent, wide: Bool) -> some View {
        AgentCard(agent: agent, latest: chat.chats(with: agent).first, wide: wide, mood: settings.isConfigured ? "awake" : "sleeping") {
            Task { await chat.talk(to: agent) }
        }
        .disabled(!settings.isConfigured)
        .contextMenu {
            Button("New chat", systemImage: "square.and.pencil") { Task { await chat.startChat(with: agent) } }
            Button("Past chats", systemImage: "clock") { pastChats = agent }
            Button("Routines", systemImage: "alarm") { routinesFor = agent }
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

    private func runChoice() {
        guard let picked = choice else { return }
        choice = nil
        Task { await chat.run(picked) }
    }
}

/// One teammate: alive, in a soft wash of its colour, with the last line of its latest chat (or what it does,
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
                        figure(84)
                        text
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        figure(64).frame(maxWidth: .infinity)
                        text
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 172, alignment: .top)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(agent.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
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

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.name).font(.headline).foregroundStyle(agent.tint)
                Spacer(minLength: 4)
                if let date = latest?.updatedAt.flatMap(Wire.parse) {
                    Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(wide ? 2 : 3)
                .multilineTextAlignment(.leading)
        }
    }

    private var line: String {
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
                            Text(ConversationRow.when(date)).font(.caption).foregroundStyle(.secondary)
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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the team chat")
    }
}

/// Cards shrink a little under the finger.
private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
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
                .listRowBackground(Theme.card)
                Section {
                    let chats = chat.chats(with: agent)
                    if chats.isEmpty {
                        Text("No chats with \(agent.name) yet.").foregroundStyle(.secondary)
                    }
                    ForEach(chats) { c in
                        Button { choose(.open(c)) } label: { ConversationRow(conversation: c) }
                            .listRowBackground(c.id == chat.conversationID ? Theme.chip : Theme.card)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { chats[$0] }
                        Task { for c in doomed { await chat.delete(c) } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
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
