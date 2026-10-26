import SwiftUI

/// Things Aide keeps in mind between chats. Added here or by asking in chat ("remember that…"). Shared items
/// are for every agent; the others belong to one specialist.
struct MemoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @State private var items: [MemoryItem] = []
    @State private var adding = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section {
                if items.isEmpty && loaded {
                    Text("Nothing yet. Tap + to add something, like \"I'm vegetarian\" or \"My dentist is Dr. Rossi\", or say \"remember that…\" in a chat.")
                        .foregroundStyle(.secondary)
                }
                rows(items.filter { $0.agent == nil })
            } header: {
                if specialists.count > 0 { Text("Everyone") }
            } footer: {
                Text(specialists.isEmpty ? "Aide reads these at the start of every chat."
                     : "Every agent reads these at the start of a chat.")
            }
            ForEach(owners, id: \.self) { id in
                let agent = chat.agent(id)
                Section {
                    rows(items.filter { $0.agent == id })
                } header: {
                    Label { Text(agent.name) } icon: { AgentMark(agent: agent, size: 18) }
                } footer: {
                    Text("Only \(agent.name) reads these.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NewMemorySheet(agents: specialists) { text, owner in await add(text, owner: owner) }
        }
        .task { await load() }
    }

    private var specialists: [Agent] { chat.agents.filter { !$0.orchestrator } }

    /// Agents with items of their own, in the agents' order (unknown ones last).
    private var owners: [String] {
        let ids = Set(items.compactMap(\.agent))
        return chat.agents.map(\.id).filter(ids.contains) + ids.subtracting(chat.agents.map(\.id)).sorted()
    }

    private func rows(_ list: [MemoryItem]) -> some View {
        ForEach(list) { Text($0.text) }
            .onDelete { offsets in
                let doomed = offsets.map { list[$0] }
                Task { for item in doomed { await remove(item) } }
            }
    }

    private func load() async {
        do { items = try await env.api.memory(); error = nil } catch { self.error = describe(error) }
        loaded = true
    }

    private func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't support Memory yet. Update the server first." }
        return error.localizedDescription
    }

    /// False when it didn't save, so the sheet stays open with the text.
    private func add(_ text: String, owner: String?) async -> Bool {
        do {
            items.insert(try await env.api.addMemory(text, agent: owner), at: 0)
            error = nil
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    private func remove(_ item: MemoryItem) async {
        do {
            try await env.api.deleteMemory(item.id)
            items.removeAll { $0.id == item.id }
        } catch { self.error = describe(error) }
    }
}

/// Something new to remember, and who reads it: everyone, or one specialist.
private struct NewMemorySheet: View {
    let agents: [Agent]
    let save: (String, String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// nil is everyone.
    @State private var owner: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Something Aide should remember", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                }
                if !agents.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("Everyone", tint: Theme.accent, selected: owner == nil) {
                                    Image(systemName: "person.2.fill").font(.caption)
                                } action: { owner = nil }
                                ForEach(agents) { agent in
                                    chip(agent.name, tint: agent.tint, selected: owner == agent.id) {
                                        AgentMark(agent: agent, size: 16)
                                    } action: { owner = agent.id }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .listRowInsets(EdgeInsets())
                    } header: {
                        Text("Who reads it")
                    } footer: {
                        Text(owner == nil ? "Every agent reads it at the start of a chat."
                             : "Only \(agents.first { $0.id == owner }?.name ?? "this agent") reads it. Aide sees it too.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("New memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            saving = true
                            if await save(trimmed, owner) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func chip<Icon: View>(_ title: String, tint: Color, selected: Bool, @ViewBuilder icon: () -> Icon,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? tint : .primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? tint.opacity(0.15) : Theme.chip, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}
