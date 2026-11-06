import SwiftUI

/// The voice-chat half of the chat screen: status, the voice conversation so far as a chat (your words in bubbles,
/// the replies with their cards and the team's talk, older ones moving up), what you're saying now at the bottom,
/// anything waiting for your yes, and End. Pebble itself stays above, grown big (tap it to send without waiting for
/// the pause).
struct VoicePanel: View {
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var chat: ChatViewModel
    /// How many of the chat's messages came before the voice started: the panel shows the ones after.
    @State private var start: Int?

    private var status: String {
        switch voice.phase {
        case .off: " "
        case .waiting: "Listening…"
        case .hearing: "Listening"
        case .transcribing: "Writing it down…"
        case .thinking: voice.step ?? "Thinking…"
        case .speaking: "Speaking"
        }
    }

    /// This voice conversation's requests and replies, as the chat has them (a call's row left out).
    private var said: ArraySlice<ChatViewModel.Message> {
        let from = min(start ?? chat.messages.count, chat.messages.count)
        return chat.messages[from...]
    }

    /// What you're saying (or said) that isn't in the chat yet.
    private var yours: String? {
        let text = (voice.phase == .hearing ? voice.transcript : voice.said).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, voice.phase != .off else { return nil }
        if said.last(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            return nil
        }
        return text
    }

    /// Aide's answer as it's written (the turn-at-a-time voice streams it), until it's in the chat.
    private var draft: String? {
        let live = chat.liveReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty, voice.phase == .thinking || voice.phase == .speaking else { return nil }
        return live
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(status).font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(said.filter { $0.call == nil }) { message in
                            if message.role == .user {
                                you(message.text)
                            } else {
                                answer(message)
                            }
                        }
                        if let yours { you(yours) }
                        if !chat.liveTeam.isEmpty { // the team's messages while the turn works
                            TeamThread(messages: chat.liveTeam, live: true)
                        }
                        if let draft {
                            HStack {
                                RichText(text: draft, isError: false)
                                Spacer(minLength: 32)
                            }
                            .padding(.horizontal, 2)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .animation(.easeOut(duration: 0.25), value: chat.messages.count)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: yours) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.liveTeam.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { if start == nil { start = chat.messages.count } }

            if !chat.pending.isEmpty { PendingCard() }

            if let error = voice.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20)
            }

            Button { voice.stopAll() } label: {
                Label("End", systemImage: "stop.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.vertical, 18)
        }
    }

    /// A reply, as in the chat: who was asked, the words, its cards.
    @ViewBuilder
    private func answer(_ message: ChatViewModel.Message) -> some View {
        if !message.team.isEmpty {
            TeamThread(messages: message.team)
        } else if !message.consulted.isEmpty {
            ConsultedRow(agents: message.consulted.map { chat.agent($0) })
        }
        HStack {
            RichText(text: message.text, isError: message.isError)
            Spacer(minLength: 32)
        }
        .padding(.horizontal, 2)
        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
            AttachmentCard(attachment: attachment, said: message.text)
        }
    }

    /// Your words, in the chat's bubble.
    private func you(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 56)
            Text(text)
                .foregroundStyle(Theme.userBubbleText)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
