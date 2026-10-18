import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var digest: DigestViewModel
    @EnvironmentObject private var env: AppEnvironment
    @State private var draft = ""
    @State private var showChats = false
    @State private var justReplied = false
    @State private var touch: CGPoint?
    @FocusState private var composerFocused: Bool

    /// Pebble's expression follows what's happening (brand/README.md).
    private var mood: String {
        if !settings.isConfigured || chat.loadError != nil { return "sleeping" }
        if chat.isSending || chat.isActing { return "thinking" }
        if justReplied { return "happy" }
        return composerFocused ? "awake" : "calm"
    }

    private var isEmpty: Bool { chat.messages.isEmpty && !chat.isSending }
    private var showsDigest: Bool { isEmpty && settings.isConfigured && digest.hasDigests }

    /// Top safe-area inset of the window, so the small Pebble can sit in the navigation bar.
    private var windowTopInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        GeometryReader { geo in
            stack.overlay(alignment: .topLeading) {
                let top = geo.frame(in: .global).minY
                PebbleStage(area: geo.size,
                            dockedY: windowTopInset + 22 - top,
                            heroY: showsDigest ? windowTopInset + 240 - top : geo.size.height * 0.33,
                            isEmpty: isEmpty, introDone: env.introDone,
                            busy: chat.isSending || chat.isActing, mood: mood, touch: touch)
            }
            .task {
                try? await Task.sleep(for: .seconds(1.8)) // let the big Pebble say hello first
                env.introDone = true
            }
        }
    }

    private var stack: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if !chat.pending.isEmpty { PendingCard() }
                composer
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chats", systemImage: "list.bullet") { showChats = true }
                        .disabled(!settings.isConfigured)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        chat.startNewChat()
                        composerFocused = true
                    }
                    Menu {
                        Button("Think harder", systemImage: "brain") { Task { await chat.think() } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(!settings.isConfigured)
                }
            }
            .sheet(isPresented: $showChats) { ChatsView() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { touch = $0.location }
                    .onEnded { _ in touch = nil })
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if chat.messages.isEmpty && !chat.isSending { emptyState }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.5, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .move(edge: .bottom))
                                    .combined(with: .opacity),
                                removal: .opacity))
                    }
                    if chat.isSending { ThinkingRow() }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.42, dampingFraction: 0.72), value: chat.messages)
            }
            .scrollDismissesKeyboard(.immediately)
            .defaultScrollAnchor(showsDigest ? .top : isEmpty ? .center : .bottom)
            .onTapGesture { composerFocused = false }
            .onChange(of: chat.messages) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.pending) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.isSending) { _, sending in
                scrollToBottom(proxy)
                if !sending, chat.messages.last?.role == .assistant, chat.messages.last?.isError == false {
                    justReplied = true
                    Task { try? await Task.sleep(for: .seconds(2)); justReplied = false }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Color.clear.frame(height: 320) // room for the big Pebble, which is drawn above
            if settings.isConfigured {
                if digest.hasDigests {
                    DigestView(digest: digest.digest).multilineTextAlignment(.leading)
                } else {
                    Text(chat.loadError ?? "What can I do for you?").font(.title3.weight(.medium))
                    VStack(spacing: 8) {
                        suggestion("What's on my calendar today?", send: true)
                        suggestion("Remind me to ", send: false)
                        suggestion("Remember that ", send: false)
                    }
                }
            } else {
                Text("Add your server token in Settings to start.").foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 24)
    }

    private func suggestion(_ text: String, send: Bool) -> some View {
        Button {
            if send { Task { await chat.send(text) } } else { draft = text; composerFocused = true }
        } label: {
            Text(text.trimmingCharacters(in: .whitespaces) + (send ? "" : "…"))
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Aide", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button {
                let text = draft
                draft = ""
                Task { await chat.send(text) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
                    .opacity(canSend ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private var canSend: Bool {
        settings.isConfigured && !chat.isSending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Your messages sit in Slate bubbles; Aide's reply is plain text on the page, like Pebble speaking.
private struct MessageRow: View {
    let message: ChatViewModel.Message

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 56)
                Text(message.text.markdown)
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.userBubbleText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            HStack {
                RichText(text: message.text, isError: message.isError)
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 2)
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
            ForEach(chat.pending) { Text($0.summary).font(.callout) }
            HStack(spacing: 10) {
                Button { Task { await chat.confirm() } } label: { Text("Confirm").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button(role: .cancel) { Task { await chat.cancel() } } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(chat.isActing)
        }
        .padding(14)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
