import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if !chat.pending.isEmpty { PendingCard() }
                composer
            }
            .background(Theme.background)
            .navigationTitle("Aide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New conversation", systemImage: "square.and.pencil") {
                            Task { await chat.newConversation() }
                        }
                        Button("Think harder", systemImage: "brain") {
                            Task { await chat.think() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(!settings.isConfigured)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chat.messages.isEmpty && !chat.isSending {
                        emptyState
                    }
                    ForEach(chat.messages) { MessageBubble(message: $0) }
                    if chat.isSending { ThinkingRow() }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.isSending) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.pending) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            PebbleMark(size: 72).foregroundStyle(Theme.accent)
            if settings.isConfigured {
                Text(chat.loadError ?? "Ask about your day, or tell me what to remember.")
            } else {
                Text("Add your server token in Settings to start.")
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.top, 80)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Aide", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let text = draft
                draft = ""
                Task { await chat.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        settings.isConfigured && !chat.isSending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MessageBubble: View {
    let message: ChatViewModel.Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text.markdown)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var foreground: Color {
        if message.isError { return .red }
        return message.role == .user ? Theme.userBubbleText : .primary
    }

    private var background: Color {
        message.role == .user ? Theme.userBubble : Theme.card
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Aide is thinking…").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// Actions waiting for the user's yes, worded by the server's code rather than the model.
private struct PendingCard: View {
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(chat.pending.count == 1 ? "Waiting for your OK" : "\(chat.pending.count) changes waiting for your OK")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(chat.pending) { action in
                Text(action.summary).font(.callout)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await chat.confirm() }
                } label: {
                    Text("Confirm").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .cancel) {
                    Task { await chat.cancel() }
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(chat.isActing)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.25)))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
