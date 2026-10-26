import SwiftUI

/// The voice-chat half of the chat screen: status, this turn as in the chat (your words in a bubble, the reply with
/// its cards and the team's talk), anything waiting for your yes, and End.
/// Pebble itself stays above, grown big (tap it to send without waiting for the pause). Everything comes from the voice turn's `phase`, so nothing from an
/// earlier turn shows while you talk.
struct VoicePanel: View {
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var chat: ChatViewModel

    private var status: String {
        switch voice.phase {
        case .off: " "
        case .waiting: "Listening…"
        case .hearing: "Listening"
        case .transcribing: "Writing it down…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        }
    }

    /// Aide's answer this turn: as it's written, then the reply itself while it's read out.
    private var reply: ChatViewModel.Message? {
        let live = chat.liveReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty, voice.phase == .thinking || voice.phase == .speaking {
            return ChatViewModel.Message(role: .assistant, text: live)
        }
        guard voice.phase == .speaking || voice.phase == .waiting && !voice.said.isEmpty else { return nil }
        return chat.messages.last { $0.role == .assistant }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(status).font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch voice.phase {
                    case .off: EmptyView()
                    case .hearing:
                        if !voice.transcript.isEmpty { you(voice.transcript) }
                    case .waiting:
                        // The turn before, faded, until you start talking.
                        exchange.opacity(0.45)
                    case .transcribing, .thinking, .speaking:
                        exchange
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.top)

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

    @ViewBuilder
    private var exchange: some View {
        if !voice.said.isEmpty { you(voice.said) }
        if chat.isSending, !chat.liveTeam.isEmpty {
            TeamThread(messages: chat.liveTeam, live: true)
        } else if let reply, !reply.consulted.isEmpty {
            ConsultedRow(agents: reply.consulted.map { chat.agent($0) })
        }
        if let reply {
            HStack {
                RichText(text: reply.text, isError: reply.isError)
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 2)
            ForEach(Array(reply.attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentCard(attachment: attachment)
            }
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
