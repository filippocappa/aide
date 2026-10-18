import SwiftUI

/// All chats, newest first. Opening one makes it the current chat.
struct ChatsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if chat.conversations.isEmpty {
                    Text("No chats yet. Start one with the new chat button.").foregroundStyle(.secondary)
                }
                ForEach(chat.conversations) { c in
                    Button {
                        Task { await chat.open(c); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title ?? "New chat").font(.body.weight(.medium)).foregroundStyle(.primary)
                            if let preview = c.preview, !preview.isEmpty {
                                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(c.id == chat.conversationID ? Theme.chip : Theme.card)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { chat.conversations[$0] }
                    Task { for c in doomed { await chat.delete(c) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await chat.loadConversations() }
        }
    }
}
