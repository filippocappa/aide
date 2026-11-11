import SwiftUI

/// A command typed in a chat's message box: "/new", "/coach how did I sleep". Typing "/" lists them over the box;
/// sending one runs it instead of sending a message. Text that isn't a command ("/etc/hosts") is sent as typed.
struct SlashCommand: Identifiable {
    let name: String
    let summary: String
    let icon: String
    /// Takes what's written after the name ("/coach how did I sleep"): picking it fills the box instead of running.
    var takesText = false
    /// Runs it, with the text after the name (empty when there's none).
    let run: (String) -> Void

    var id: String { name }

    /// `draft` split into the command it names and the rest, when it starts with one of `commands`.
    static func parse(_ draft: String, in commands: [SlashCommand]) -> (SlashCommand, String)? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let word = text.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard let command = commands.first(where: { $0.name == word }) else { return nil }
        let rest = text.dropFirst(1 + word.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, rest)
    }

    /// The commands to list while `draft` is being typed: those starting with what follows "/", until a space.
    static func matches(_ draft: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return [] }
        let typed = draft.dropFirst()
        if let space = typed.firstIndex(where: \.isWhitespace) { // past the name: only the one it names, as a hint
            let word = typed[..<space].lowercased()
            return commands.filter { $0.name == word && $0.takesText }
        }
        let word = typed.lowercased()
        return commands.filter { $0.name.hasPrefix(word) }
    }
}

/// The commands that match what's typed, over the message box.
struct SlashCommandList: View {
    let commands: [SlashCommand]
    var tint: Color = Theme.accent
    let pick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { command in
                Button { pick(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 22)
                        Text("/" + command.name).font(.subheadline.weight(.semibold).monospaced())
                        Text(command.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        #if os(macOS)
        .frame(maxWidth: MessageBoxGlass.column)
        .padding(.horizontal, 16)
        #else
        .padding(.horizontal, 12)
        #endif
        .padding(.bottom, 2)
    }
}
