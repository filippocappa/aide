import SwiftUI

/// The voice-chat half of the chat screen: status, the words said so far, and an End button.
/// Pebble itself stays above, grown big.
struct VoicePanel: View {
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var chat: ChatViewModel

    private var status: String {
        if voice.isListening { return voice.transcript.isEmpty ? "Listening…" : "Listening" }
        if voice.isTranscribing { return "Writing it down…" }
        if voice.isSpeaking { return "Speaking" }
        if chat.isSending { return "Thinking…" }
        return " "
    }

    private var lastUser: ChatViewModel.Message? { chat.messages.last { $0.role == .user } }
    private var lastReply: ChatViewModel.Message? { chat.messages.last { $0.role == .assistant } }

    var body: some View {
        VStack(spacing: 0) {
            Text(status).font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 12)

            // What was said, so you can read as well as hear.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if voice.isListening, !voice.transcript.isEmpty {
                        line("You", voice.transcript)
                    } else if let u = lastUser {
                        line("You", u.text)
                    }
                    if !voice.isListening || voice.transcript.isEmpty, let r = lastReply, lastUser != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.agent.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            RichText(text: r.text, isError: r.isError)
                        }
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

    private func line(_ who: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.medium))
        }
    }
}
