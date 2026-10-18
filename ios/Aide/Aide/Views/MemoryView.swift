import SwiftUI

/// Things Aide keeps in mind between chats. Added here or by asking in chat ("remember that…").
struct MemoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var items: [MemoryItem] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Something Aide should remember", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                    // Borderless, or the List turns the whole row into this button: tapping the
                    // empty field then hit the disabled Add instead of opening the keyboard.
                    Button { Task { await add() } } label: {
                        Text("Add")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section {
                if items.isEmpty && loaded {
                    Text("Nothing yet. Try \"I'm vegetarian\" or \"My dentist is Dr. Rossi\".").foregroundStyle(.secondary)
                }
                ForEach(items) { Text($0.text) }
                    .onDelete { offsets in
                        let doomed = offsets.map { items[$0] }
                        Task { for item in doomed { await remove(item) } }
                    }
            } footer: {
                Text("Aide reads these at the start of every chat.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do { items = try await env.api.memory(); error = nil } catch { self.error = describe(error) }
        loaded = true
    }

    private func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't support Memory yet. Update the server first." }
        return error.localizedDescription
    }

    private func add() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            items.insert(try await env.api.addMemory(text), at: 0)
            draft = ""
            error = nil
        } catch { self.error = describe(error) }
    }

    private func remove(_ item: MemoryItem) async {
        do {
            try await env.api.deleteMemory(item.id)
            items.removeAll { $0.id == item.id }
        } catch { self.error = describe(error) }
    }
}
