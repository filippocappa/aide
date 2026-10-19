import SwiftUI

/// The agents along the top (tap one for a new chat with it), then all chats, newest first, each with its
/// agent's Pebble. Opening one makes it the current chat.
struct ChatsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AgentRow { agent in
                        Task {
                            agent.orchestrator ? await chat.startNewChat() : await chat.newChat(with: agent)
                        }
                        dismiss()
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                Section {
                    if chat.conversations.isEmpty {
                        Text("No chats yet. Tap someone above to start one.").foregroundStyle(.secondary)
                    }
                    ForEach(chat.conversations) { c in
                        Button {
                            Task { await chat.open(c); dismiss() }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                PebbleMark(size: 24).foregroundStyle(chat.agent(c.agent).tint).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title ?? "New chat").font(.body.weight(.medium)).foregroundStyle(.primary)
                                    if let preview = c.preview, !preview.isEmpty {
                                        Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(c.id == chat.conversationID ? Theme.chip : Theme.card)
                        .accessibilityHint(chat.agent(c.agent).name)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { chat.conversations[$0] }
                        Task { for c in doomed { await chat.delete(c) } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                async let agents: Void = chat.loadAgents()
                await chat.loadConversations()
                await agents
            }
        }
    }
}

/// One Pebble per agent in its colour, with its name underneath. Scrolls sideways if they don't fit.
private struct AgentRow: View {
    @EnvironmentObject private var chat: ChatViewModel
    let start: (Agent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(chat.agents) { agent in
                    Button { start(agent) } label: {
                        VStack(spacing: 6) {
                            PebbleMark(size: 40)
                                .foregroundStyle(agent.tint)
                                .frame(width: 60, height: 60)
                                .background(Theme.card, in: Circle())
                                .overlay {
                                    if agent.id == chat.agentID {
                                        Circle().strokeBorder(agent.tint, lineWidth: 2)
                                    }
                                }
                            Text(agent.name).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        }
                        .frame(width: 66)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New chat with \(agent.name)")
                    .accessibilityHint(agent.role)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
