import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var voice: VoiceController
    @State private var draft = ""
    @State private var showChats = false
    @State private var showDigest = false
    @State private var tapCount = 0
    @State private var justReplied = false
    @FocusState private var composerFocused: Bool

    /// Pebble's expression follows what's happening (brand/README.md).
    private var mood: String {
        if !settings.isConfigured || chat.loadError != nil { return "sleeping" }
        if voice.isListening { return "awake" }
        if voice.isSpeaking { return "happy" }
        if chat.isSending || chat.isActing { return "thinking" }
        if justReplied { return "happy" }
        return composerFocused ? "awake" : "calm"
    }

    private static let headerPebble: CGFloat = 84
    private static let voicePebble: CGFloat = 250

    private var isEmpty: Bool { chat.messages.isEmpty && !chat.isSending }

    private var replying: Bool { (chat.isSending || chat.isActing) && !voice.isActive }

    var body: some View {
        VStack(spacing: 0) {
            // One Pebble, always centred. In a voice chat it grows and the chat gives way to the voice panel.
            // It's laid out once at full size and only scaled, so growing can't shift it sideways.
            ZStack(alignment: .top) {
                LivePebble(mood: mood, size: Self.voicePebble, energy: voice.isListening ? voice.level : 0,
                           bounceTrigger: tapCount + chat.messages.count)
                    .foregroundStyle(Theme.accent)
                    // a little bigger while it answers
                    .scaleEffect((voice.isActive ? 1 : Self.headerPebble / Self.voicePebble) * (replying ? 1.3 : 1), anchor: .top)
                    // In the header it reaches up beside the Dynamic Island, level with the buttons.
                    .offset(y: voice.isActive ? 40 : -10)
                    .frame(maxWidth: .infinity)
                    .frame(height: voice.isActive ? 330 : Self.headerPebble, alignment: .top)
                if !voice.isActive { buttons.transition(.opacity) }
            }
            // Stacked rather than one after the other, so the chat and the voice panel cross-fade
            // in the same space instead of squeezing each other (and the End button) mid-animation.
            ZStack {
                if voice.isActive {
                    VoicePanel().transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        transcript
                        if !chat.pending.isEmpty { PendingCard() }
                        composer
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: voice.isActive)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: replying)
        .background(Theme.background)
        .background(TouchTracker(tapCount: $tapCount))
        .sheet(isPresented: $showChats) { ChatsView() }
        .sheet(isPresented: $showDigest) { DigestSheet() }
        .onChange(of: voice.transcript) { _, text in if voice.isListening { draft = text } }
        .onChange(of: voice.isListening) { _, listening in if !listening { draft = "" } }
    }

    /// Chat controls on either side of Pebble.
    private var buttons: some View {
        HStack(spacing: 8) {
            headerButton("list.bullet", label: "Chats") { showChats = true }
                .disabled(!settings.isConfigured)
            headerButton("sun.horizon", label: "Digest") { showDigest = true }
                .disabled(!settings.isConfigured)
            Spacer()
            headerButton("square.and.pencil", label: "New chat") {
                chat.startNewChat()
                composerFocused = true
            }
            Menu {
                Button("Think harder", systemImage: "brain") { Task { await chat.think() } }
            } label: {
                headerIcon("ellipsis")
            }
            .disabled(!settings.isConfigured)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { headerIcon(icon) }.accessibilityLabel(label)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 40, height: 40)
            .background(Theme.chip, in: Circle())
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
            .defaultScrollAnchor(isEmpty ? .center : .bottom)
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
            if settings.isConfigured {
                // The digest lives behind the sun button, so a new chat starts clean.
                Text(chat.loadError ?? "What can I do for you?").font(.title3.weight(.medium))
                VStack(spacing: 8) {
                    suggestion("What's on my calendar today?", send: true)
                    suggestion("Remind me to ", send: false)
                    suggestion("Remember that ", send: false)
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
                if showsMic {
                    Task { await voice.toggle() }
                } else {
                    let text = draft
                    draft = ""
                    Task { await chat.send(text) }
                }
            } label: {
                Image(systemName: showsMic ? (voice.isActive ? "stop.fill" : "mic.fill") : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
                    .opacity(canSend || showsMic ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(!canSend && !showsMic)
            .accessibilityLabel(showsMic ? (voice.isActive ? "Stop voice chat" : "Talk to Aide") : "Send")
        }
        // No background of its own: the page's shows through, and an opaque band here would fade
        // out over the voice panel's End button as a visible stripe.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// An empty message box offers the microphone instead of send.
    private var showsMic: Bool {
        settings.isConfigured && !chat.isSending
            && (voice.isActive || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
