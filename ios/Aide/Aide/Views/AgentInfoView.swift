import SwiftUI

/// What an agent runs on (docs/API.md, "Agents"): the connectors it reaches, read-only or not, and the
/// instructions it's given before every chat. Read-only: both are set on the server.
struct AgentInfoSheet: View {
    let agent: Agent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        LivePebble(mood: "awake", size: 88, figure: agent.figure)
                            .foregroundStyle(agent.tint)
                        Text(agent.name).font(.title2.bold())
                        Text(agent.role).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                if agent.prompt.isEmpty {
                    Text("The server doesn't share this yet. Update it to see \(agent.name)'s connectors and instructions.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.row)
                } else {
                    Section {
                        ForEach(agent.connectors) { connector in
                            ConnectorRow(connector: connector, tint: agent.tint).listRowBackground(Theme.row)
                        }
                    } header: {
                        Text("Connectors")
                    } footer: {
                        Text("What \(agent.name) can reach right now. Anything that sends, changes or deletes waits for your OK.")
                    }
                    Section {
                        Text(agent.prompt)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .listRowBackground(Theme.row)
                    } header: {
                        Text("Instructions")
                    } footer: {
                        Text("What \(agent.name) is told before every chat. What it remembers about you comes on top, in Settings → What Aide remembers.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("About \(agent.name)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.grouped)
    }
}

/// A connector: what it reaches, whether it can only read, and its tools.
private struct ConnectorRow: View {
    let connector: Agent.Connector
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(connector.id))
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                Text(connector.tools.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connector.readOnly {
                Text("Read only").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
