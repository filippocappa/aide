import SwiftUI

/// An agent's profile (docs/API.md, "Agents"): its figure over a glow of its colour, a way into a chat, what it keeps an
/// eye on (its routines and watches), the connectors it reaches, and the instructions it's given before every chat
/// behind a row. The buttons leave the sheet: whoever shows it runs `act` once it's gone.
struct AgentInfoSheet: View {
    enum Action { case newChat, starter(String), pastChats, routines, activity, thinkHarder, quiz, practiceExam }

    @EnvironmentObject private var chat: ChatViewModel
    let agent: Agent
    /// Nil: a profile to read only, without the buttons.
    var act: ((Action) -> Void)?
    var showsActivity = true
    /// Opened from a chat's ••• button: the profile carries that chat's own buttons too (a course chat's quiz and
    /// practice exam).
    var inChat = false
    var course = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if let act {
                        HStack(spacing: 10) {
                            button("New chat", filled: true) { act(.newChat) }
                            button("Past chats", filled: false) { act(.pastChats) }
                        }
                        if !starters.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(starters, id: \.self) { s in Chip(title: s) { act(.starter(s)) } }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.horizontal, -16)
                        }
                    }
                    if let act, inChat { chatButtons(act) }
                    if !routines.isEmpty || act != nil { watching }
                    if agent.prompt.isEmpty {
                        Text("The server doesn't share this yet. Update it to see \(agent.name)'s connectors and instructions.")
                            .foregroundStyle(.secondary)
                            .card()
                    } else {
                        DetailCard("Can reach",
                                   note: "Anything that sends, changes or deletes waits for your OK.", padding: 0) {
                            ForEach(Array(agent.connectors.enumerated()), id: \.element.id) { i, connector in
                                if i > 0 { RowDivider(leading: 52) }
                                ConnectorRow(connector: connector)
                            }
                        }
                        VStack(spacing: 0) {
                            NavigationLink {
                                InstructionsPage(agent: agent)
                            } label: {
                                linkRow("How \(agent.name) is told to work", icon: "doc.text")
                            }
                            if let act, showsActivity {
                                RowDivider(leading: 52)
                                Button { act(.activity) } label: {
                                    linkRow("What \(agent.name) did", icon: "list.bullet.rectangle")
                                }
                            }
                        }
                        .buttonStyle(RowPress())
                        .card(padding: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .pageGlow(agent.tint)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.grouped)
    }

    private var header: some View {
        VStack(spacing: 6) {
            LivePebble(mood: "awake", size: 92, figure: agent.figure)
                .foregroundStyle(agent.tint)
                .padding(.bottom, 6)
            Text(agent.name).font(.title.bold())
            Text(agent.role).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }

    /// The starters that send as they are ("Remind me to " needs the rest typed, so it stays in the chat).
    private var starters: [String] {
        let all = agent.starters.isEmpty && agent.orchestrator ? Agent.aide.starters : agent.starters
        return all.filter { !$0.hasSuffix(" ") }
    }

    private var routines: [Routine] {
        chat.routines(of: agent).sorted { ($0.isWatch ? 0 : 1, $0.time) < ($1.isWatch ? 0 : 1, $1.time) }
    }

    /// Its routines and watches with when they run; the row under them opens the routines sheet.
    private var watching: some View {
        DetailCard("Keeps an eye on", note: "Routines are jobs \(agent.name) does on its own at their time, each "
                   + "posting in a chat of its own. The ones with an eye are watches: they check on time and only post "
                   + "when something needs you.", padding: 0) {
            ForEach(Array(routines.enumerated()), id: \.element.id) { i, r in
                if i > 0 { RowDivider(leading: 52) }
                StatusRow(r.title, detail: Schedule.label(time: r.time, days: r.days)) {
                    Image(systemName: r.isWatch ? "eye" : "alarm").foregroundStyle(.secondary)
                }
                .opacity(r.enabled ? 1 : 0.5)
            }
            if let act {
                if !routines.isEmpty { RowDivider(leading: 52) }
                Button { act(.routines) } label: {
                    linkRow(routines.isEmpty ? "Add a routine" : "Routines", icon: routines.isEmpty ? "plus" : "slider.horizontal.3")
                }
                .buttonStyle(RowPress())
            }
        }
    }

    /// What this chat can do: think harder for the rest of it; in a course chat, a quiz by voice and a practice exam.
    private func chatButtons(_ act: @escaping (Action) -> Void) -> some View {
        DetailCard("This chat", padding: 0) {
            Button { act(.thinkHarder) } label: { linkRow("Think harder", icon: "brain", detail: "The smarter model for the rest of it") }
            if course {
                RowDivider(leading: 52)
                Button { act(.quiz) } label: { linkRow("Quiz me", icon: "waveform", detail: "By voice, from the notebook") }
                RowDivider(leading: 52)
                Button { act(.practiceExam) } label: { linkRow("Practice exam", icon: "checklist") }
            }
        }
        .buttonStyle(RowPress())
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(filled ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(filled ? AnyShapeStyle(agent.orchestrator ? Theme.slate : agent.tint) : AnyShapeStyle(Theme.row),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(CardPress())
    }

    private func linkRow(_ title: String, icon: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// What an agent is told before every chat, to read.
private struct InstructionsPage: View {
    let agent: Agent

    var body: some View {
        ScrollView {
            DetailCard(note: "What \(agent.name) is told before every chat. What it remembers about you comes on top, in Settings → Memory.") {
                Text(agent.prompt).font(.footnote).textSelection(.enabled)
            }
            .padding(16)
        }
        .background(Theme.grouped)
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// A connector: what it reaches, and whether it can only read.
private struct ConnectorRow: View {
    let connector: Agent.Connector

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(connector.id)).foregroundStyle(.secondary).frame(width: 28)
            Text(connector.name)
            Spacer()
            if connector.readOnly {
                Text("Read only")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.chip, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private static func icon(_ id: String) -> String {
        switch id {
        case "calendar": "calendar"
        case "reminders": "checklist"
        case "mail": "envelope"
        case "health": "heart"
        case "habits": "flame"
        case "food": "fork.knife"
        case "web": "globe"
        case "maps": "map"
        case "memory": "brain"
        case "routines": "alarm"
        case "team": "person.3"
        default: "puzzlepiece.extension"
        }
    }
}
