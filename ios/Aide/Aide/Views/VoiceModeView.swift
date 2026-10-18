import SwiftUI

/// Full-screen voice chat: you and Pebble, with the words you can read underneath.
struct VoiceModeView: View {
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var chat: ChatViewModel
    let mood: String

    private var status: String {
        if voice.isListening { return voice.transcript.isEmpty ? "Listening…" : "Listening" }
        if voice.isSpeaking { return "Speaking" }
        if chat.isSending { return "Thinking…" }
        return " "
    }

    private var lastUser: ChatViewModel.Message? { chat.messages.last { $0.role == .user } }
    private var lastReply: ChatViewModel.Message? { chat.messages.last { $0.role == .assistant } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { voice.stopAll() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.chip, in: Circle())
                }
                .accessibilityLabel("End voice chat")
            }
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer(minLength: 0)
            LivePebble(mood: mood, size: 260, energy: voice.isListening ? voice.level : 0)
                .foregroundStyle(Theme.accent)
            Text(status).font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
            Spacer(minLength: 0)

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
                            Text("Aide").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            RichText(text: r.text, isError: r.isError)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 260)
            .defaultScrollAnchor(.top)

            Button { voice.stopAll() } label: {
                Label("End", systemImage: "stop.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.vertical, 18)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let error = voice.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.top, 56).padding(.horizontal, 20)
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
