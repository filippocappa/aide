import SwiftUI

/// The agents' group chat (docs/API.md, "Team talk"): every time Aide asked one of the others and what they
/// answered, from all of Aide's chats, plus what you write here. Without a mention Aide answers (and may ask the
/// others); @mention someone to pick who answers. Long-press a message to open the chat it came from.
struct TeamChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    /// Picked with "Open chat": the home screen opens it once this screen is gone.
    let open: (String) -> Void
    @State private var draft = ""
    /// Bumped on every send: the message box starts a new text field (`MessageBox.reset`).
    @State private var sent = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var working: Agent? { chat.teamWorking.map { chat.agent($0) } }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !chat.pending.isEmpty { PendingCard() }
            composer
        }
        .overlay(alignment: .top) { header }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await chat.loadTeam() }
    }

    private static let headerHeight: CGFloat = 56

    private var header: some View {
        ZStack(alignment: .top) {
            HeaderBackdrop()
                .ignoresSafeArea(edges: .top)
                .frame(height: Self.headerHeight + 28)
                .allowsHitTesting(false)
            HStack {
                Button { dismiss() } label: { HeaderIcon(name: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chats")
                Spacer()
            }
            .overlay { HeaderTitle(text: "Team chat") }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if chat.team.isEmpty { empty }
                    ForEach(Array(chat.team.enumerated()), id: \.offset) { index, message in
                        if let day = dayLabel(at: index) {
                            Text(day)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                        }
                        Group {
                            if message.from == "user" {
                                MineBubble(text: message.text)
                            } else {
                                TeamBubble(message: message, from: chat.agent(message.from),
                                           to: message.to == "team" ? nil : chat.agent(message.to))
                            }
                        }
                        .contextMenu {
                            if let id = message.conversationId {
                                Button("Open chat", systemImage: "bubble.left.and.bubble.right") { open(id) }
                            }
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        }
                        .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    if let working {
                        HStack(spacing: 10) {
                            LivePebble(mood: "thinking", size: 32, figure: working.figure)
                                .foregroundStyle(working.tint)
                                .allowsHitTesting(false)
                            Text("\(working.name) is writing…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if chat.isPostingTeam {
                        ThinkingDots()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.28), value: chat.team.count)
                .animation(.easeInOut(duration: 0.2), value: chat.teamWorking)
            }
            .defaultScrollAnchor(.bottom)
            .contentMargins(.top, Self.headerHeight, for: .scrollContent) // starts below the header, scrolls under it
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await chat.loadTeam() }
            .onChange(of: chat.team.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.teamWorking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    /// What's typed after an "@" at the end of the draft ("" right after the "@"), or nil when not mentioning.
    private var mentionQuery: String? {
        let word = draft.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard word.hasPrefix("@"), !word.contains("\n") else { return nil }
        return String(word.dropFirst())
    }

    /// The agents whose id or name starts with what's typed after the "@".
    private var suggestions: [Agent] {
        guard let query = mentionQuery else { return [] }
        if query.isEmpty { return chat.agents }
        return chat.agents.filter {
            $0.id.lowercased().hasPrefix(query.lowercased()) || $0.name.lowercased().hasPrefix(query.lowercased())
        }
    }

    /// The message box. Typing "@" shows the matching agents above it: tap one to finish the mention.
    private var composer: some View {
        VStack(spacing: 8) {
            if !suggestions.isEmpty {
                mentionSuggestions.transition(.opacity.combined(with: .offset(y: 10)))
            }
            MessageBox("Message the team, @ to mention", text: $draft, focused: $focused, reset: sent) {
                SendButton(enabled: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isPostingTeam) {
                    let text = draft
                    $draft.clearMessage()
                    sent += 1
                    Task { await chat.postTeam(text) }
                }
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.15), value: suggestions.map(\.id))
        .disabled(!settings.isConfigured)
    }

    private var mentionSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { agent in
                    Button { mention(agent) } label: {
                        HStack(spacing: 5) {
                            AgentMark(agent: agent, size: 18)
                            Text("@" + agent.name).font(.footnote.weight(.medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(agent.name)")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Replaces the "@…" being typed with the agent's full mention.
    private func mention(_ agent: Agent) {
        guard let query = mentionQuery else { return }
        draft = String(draft.dropLast(query.count + 1)) + "@" + agent.id + " "
        focused = true
    }

    private var empty: some View {
        VStack(spacing: 14) {
            HStack(spacing: -8) {
                ForEach(chat.agents) { agent in
                    LivePebble(mood: "calm", size: 44, figure: agent.figure)
                        .foregroundStyle(agent.tint)
                        .allowsHitTesting(false)
                }
            }
            Text("Ask the whole team here. Aide answers, or @mention who you want. When Aide asks the others something in your chats, it shows up here too.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /// "Today", "Yesterday" or the date, above the first message of each day.
    private func dayLabel(at index: Int) -> String? {
        guard let date = chat.team[index].ts.flatMap(Wire.parse) else { return nil }
        if index > 0, let previous = chat.team[index - 1].ts.flatMap(Wire.parse),
           Calendar.current.isDate(previous, inSameDayAs: date) { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

/// One agent's message: who sent it (to whom, inside one of Aide's turns), next to its figure.
private struct TeamBubble: View {
    let message: TeamMessage
    let from: Agent
    /// nil when it's said to the whole team.
    let to: Agent?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark(agent: from, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(from.name)
                    if let to {
                        Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
                        Text(to.name).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let date = message.ts.flatMap(Wire.parse) {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .font(.subheadline.weight(.semibold))
                RichText(text: message.text).font(.callout)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What you wrote, on the right like in a chat.
private struct MineBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(text.markdown)
                .textSelection(.enabled)
                .foregroundStyle(Theme.userBubbleText)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Before the server says who's writing.
private struct ThinkingDots: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}
