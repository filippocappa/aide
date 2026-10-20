import SwiftUI

/// The voice-chat half of the chat screen: status, this turn's words, and End.
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
                        if !voice.transcript.isEmpty { line("You", voice.transcript) }
                    case .waiting:
                        // The turn before, faded, until you start talking.
                        exchange.opacity(0.45)
                    case .transcribing, .thinking, .speaking:
                        exchange
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
            .defaultScrollAnchor(.top)

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
        if !voice.said.isEmpty { line("You", voice.said) }
        if let reply {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.agent.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                RichText(text: reply.text, isError: reply.isError)
            }
        }
    }

    private func line(_ who: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.medium))
        }
    }
}
