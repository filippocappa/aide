import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showPastChats = false
    /// Picked in Past chats; run once the sheet is gone.
    @State private var pastChoice: PastChatsSheet.Choice?
    @State private var showRoutines = false
    @State private var justReplied = false
    @FocusState private var composerFocused: Bool

    /// Pebble's expression follows what's happening (brand/README.md).
    private var mood: String {
        if !settings.isConfigured || chat.loadError != nil { return "sleeping" }
        if voice.isListening { return "awake" }
        if voice.isSpeaking { return "happy" }
        if chat.isSending || chat.isActing || chat.isOpening { return "thinking" }
        if justReplied { return "happy" }
        return composerFocused ? "awake" : "calm"
    }

    private static let headerPebble: CGFloat = 84
    private static let voicePebble: CGFloat = 250

    private var isEmpty: Bool { chat.messages.isEmpty && !chat.isSending && !chat.isOpening }

    private var replying: Bool { (chat.isSending || chat.isActing) && !voice.isActive }

    var body: some View {
        ZStack(alignment: .top) {
            // The chat fills the screen and scrolls under Pebble. In a voice chat the voice panel takes its
            // place: the old one fades out quickly, then the new one fades in, so the End button and the
            // message box are never half-faded on top of each other.
            Group {
                if voice.isActive {
                    VoicePanel()
                        .padding(.top, Self.voiceHeader)
                        .transition(Self.swap)
                } else {
                    VStack(spacing: 0) {
                        transcript
                        if !chat.pending.isEmpty { PendingCard() }
                        composer
                    }
                    .transition(Self.swap)
                }
            }
            header
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: voice.isActive)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: replying)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar) // Pebble and its buttons are the header
        .sheet(isPresented: $showPastChats, onDismiss: {
            guard let picked = pastChoice else { return }
            pastChoice = nil
            Task { await chat.run(picked) }
        }) {
            PastChatsSheet(agent: chat.agent) { pastChoice = $0; showPastChats = false }
        }
        .sheet(isPresented: $showRoutines, onDismiss: {
            guard let picked = pastChoice else { return }
            pastChoice = nil
            Task { await chat.run(picked) }
        }) {
            RoutinesSheet(agent: chat.agent) { pastChoice = $0; showRoutines = false }
        }
        .onChange(of: voice.transcript) { _, text in if voice.isListening { draft = text } }
        .onChange(of: voice.isListening) { _, listening in if !listening { draft = "" } }
        .onChange(of: voice.isActive) { _, active in if active { composerFocused = false } } // no keyboard in voice
    }

    private static let voiceHeader: CGFloat = 330
    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.15)),
        removal: .opacity.animation(.easeIn(duration: 0.15)))

    /// One Pebble, always centred, over a soft blur the messages slide under. In a voice chat it grows
    /// and the blur goes. It's laid out once at full size and only scaled, so growing can't shift it sideways.
    private var header: some View {
        ZStack(alignment: .top) {
            ProgressiveBlur()
                .frame(height: Self.headerPebble + 24)
                .ignoresSafeArea(edges: .top)
                .opacity(voice.isActive ? 0 : 1)
                .allowsHitTesting(false)
            HeaderPebble(mood: mood, size: Self.voicePebble, energy: voice.isListening ? voice.level : 0,
                         messages: chat.messages.count, agent: chat.agent)
                // a little bigger while it answers
                .scaleEffect((voice.isActive ? 1 : Self.headerPebble / Self.voicePebble) * (replying ? 1.3 : 1), anchor: .top)
                // In the header it reaches up beside the Dynamic Island, level with the buttons.
                .offset(y: voice.isActive ? 40 : -10)
                .frame(maxWidth: .infinity)
                .frame(height: voice.isActive ? Self.voiceHeader : Self.headerPebble, alignment: .top)
            if !voice.isActive { buttons.transition(.opacity) }
        }
    }

    /// Chat controls on either side of Pebble.
    private var buttons: some View {
        HStack(spacing: 8) {
            headerButton("chevron.left", label: "Chats") { dismiss() }
            Spacer()
            Menu {
                Button("New chat", systemImage: "square.and.pencil") { Task { await chat.startChat(with: chat.agent) } }
                Button("Past chats", systemImage: "clock") { showPastChats = true }
                Button("Routines", systemImage: "alarm") { showRoutines = true }
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
                    if isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            if let routine = message.routine {
                                Label(routine.title, systemImage: "alarm")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 2)
                            }
                            if !message.team.isEmpty {
                                TeamThread(messages: message.team)
                            } else if !message.consulted.isEmpty {
                                ConsultedRow(agents: message.consulted.map { chat.agent($0) })
                            }
                            MessageRow(message: message)
                            if chat.startsWithDigest, message.id == chat.messages.first?.id { digestDetails }
                        }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)
                                .combined(with: .move(edge: .bottom))
                                .combined(with: .opacity),
                            removal: .opacity))
                    }
                    if chat.isOpening { ThinkingRow(label: "Getting your digest…") }
                    if chat.isSending, !chat.liveTeam.isEmpty {
                        TeamThread(messages: chat.liveTeam, live: true).transition(.opacity)
                    }
                    // While an agent works on its answer, the thread shows it thinking instead.
                    if chat.isSending, chat.liveTeam.last?.from != chat.orchestrator.id { ThinkingRow() }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.42, dampingFraction: 0.72), value: chat.messages)
            }
            .scrollDismissesKeyboard(.immediately)
            .contentMargins(.top, Self.headerPebble, for: .scrollContent) // starts below Pebble, scrolls under it
            .defaultScrollAnchor(isEmpty ? .center : .bottom)
            .onTapGesture { composerFocused = false }
            .onChange(of: chat.messages) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.pending) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.liveTeam) { _, _ in scrollToBottom(proxy) }
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

    /// Under Pebble's digest greeting: the cards it was written from.
    private var digestDetails: some View {
        Button {
            digest.kind = DigestViewModel.Kind(rawValue: chat.openedDigest ?? ChatViewModel.digestKind()) ?? .daily
            digest.isPresented = true
        } label: {
            Label("Details", systemImage: "sun.horizon")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            if settings.isConfigured {
                // The digest lives behind the sun button, so a new chat starts clean.
                if let error = chat.loadError {
                    Text(error).font(.title3.weight(.medium))
                } else if chat.agent.orchestrator {
                    Text("What can I do for you?").font(.title3.weight(.medium))
                } else {
                    VStack(spacing: 4) {
                        Text(chat.agent.name).font(.title3.weight(.semibold)).foregroundStyle(chat.agent.tint)
                        Text(chat.agent.role).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 8) {
                    ForEach(chat.agent.starters.isEmpty && chat.agent.orchestrator ? Agent.aide.starters : chat.agent.starters,
                            id: \.self) { starter in
                        suggestion(starter, send: !starter.hasSuffix(" "))
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
            TextField("Message \(chat.agent.name)", text: $draft, axis: .vertical)
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
            .accessibilityLabel(showsMic ? (voice.isActive ? "Stop voice chat" : "Talk to \(chat.agent.name)") : "Send")
        }
        // No background of its own: the page's shows through, and an opaque band here would fade
        // out over the voice panel's End button as a visible stripe.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// An empty message box offers the microphone instead of send.
    private var showsMic: Bool {
        settings.isConfigured && !chat.isSending && !chat.isOpening
            && (voice.isActive || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canSend: Bool {
        settings.isConfigured && !chat.isSending && !chat.isOpening
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RichText(text: message.text, isError: message.isError)
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 2)
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentCard(attachment: attachment)
                }
            }
        }
    }
}

/// The reminders or events a reply was about, as a card: reminders tick off right here.
private struct AttachmentCard: View {
    let attachment: Attachment

    var body: some View {
        switch attachment {
        case .reminders(let all):
            let reminders = all.filter { !$0.deleted } // deleted since the reply
            if !reminders.isEmpty { card { ReminderRows(reminders: reminders) } }
        case .events(let events):
            card { EventRows(events: events) }
        case .unknown:
            EmptyView()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Above a reply: the specialists Aide asked for it, as small Pebbles in their colours.
private struct ConsultedRow: View {
    let agents: [Agent]

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(agents) { AgentMark(agent: $0, size: 22) }
            }
            Text("Asked " + agents.map(\.name).formatted(.list(type: .and)))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What Aide and the agents it asked said to each other, as a little group chat above Aide's reply. While Aide is
/// still working it fills in live, with the asked agent thinking until its answer comes. Tap to read it all.
private struct TeamThread: View {
    @EnvironmentObject private var chat: ChatViewModel
    let messages: [TeamMessage]
    var live = false
    @State private var expanded = false

    /// The agent Aide asked last, still working on its answer.
    private var working: Agent? {
        guard live, let last = messages.last, last.from == chat.orchestrator.id else { return nil }
        return chat.agent(last.to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Team", systemImage: "person.3.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                row(message).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let working {
                HStack(spacing: 10) {
                    LivePebble(mood: "thinking", size: 26, figure: working.figure)
                        .foregroundStyle(working.tint)
                        .allowsHitTesting(false)
                    Text("\(working.name) is thinking…").font(.footnote).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages.count)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Shows less" : "Shows all of it")
    }

    private func row(_ message: TeamMessage) -> some View {
        let from = chat.agent(message.from), to = chat.agent(message.to)
        return HStack(alignment: .top, spacing: 10) {
            AgentMark(agent: from, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(from.name).foregroundStyle(from.tint)
                    Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
                    Text(to.name).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                Text(message.text.markdown)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 4)
            }
        }
    }
}

private struct ThinkingRow: View {
    var label = "Thinking…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

/// Actions waiting for the user's yes, worded by the server's code rather than the model.
struct PendingCard: View {
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

/// The chat's Pebble, bouncing at every touch on screen and every new message. The touch count lives here, not in
/// ChatView: a touch that re-rendered the whole chat would rebuild the ••• menu while it's open, and the menu would
/// drop the tap on its item.
private struct HeaderPebble: View {
    let mood: String
    let size: CGFloat
    let energy: CGFloat
    let messages: Int
    let agent: Agent
    @State private var tapCount = 0

    var body: some View {
        LivePebble(mood: mood, size: size, energy: energy, bounceTrigger: tapCount + messages, figure: agent.figure)
            .foregroundStyle(agent.tint)
            .animation(.easeInOut(duration: 0.3), value: agent.id)
            .background(TouchTracker(tapCount: $tapCount))
    }
}

/// With the navigation bar hidden, UIKit turns off the swipe from the left edge that goes back. This keeps it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// A blur that's strongest at the top and fades out downwards, so messages soften as they slide under Pebble.
private struct ProgressiveBlur: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.4),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [Theme.background.opacity(0.9), Theme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
