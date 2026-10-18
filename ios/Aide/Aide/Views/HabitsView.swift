import SwiftUI

/// Habits: tick them off, add new ones, swipe to delete. The assistant can do the same from chat.
struct HabitsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var habits: [Habit] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                if habits.isEmpty && loaded && error == nil {
                    VStack(spacing: 6) {
                        Text("No habits yet").font(.headline)
                        Text("Tap + to add one, or tell Aide in chat: \"add a gym habit, three times a week\".")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
                ForEach(habits) { habit in
                    HStack(spacing: 14) {
                        Button { Task { await toggle(habit) } } label: {
                            Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(habit.doneToday ? "Undo \(habit.name)" : "Mark \(habit.name) done")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.name).font(.body.weight(.medium))
                            Text(habit.cadenceText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if habit.streak > 0 {
                            Label("\(habit.streak)", systemImage: "flame.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.orange)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { habits[$0] }
                    Task { for h in doomed { await remove(h) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add habit", systemImage: "plus") { adding = true }.disabled(!settings.isConfigured)
                }
            }
            .sheet(isPresented: $adding) { NewHabitSheet { await add($0) } }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard settings.isConfigured else { return }
        do { habits = try await env.api.habits(); error = nil } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func toggle(_ habit: Habit) async {
        do {
            let updated = try await env.api.checkHabit(habit.id, done: !habit.doneToday)
            if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = updated }
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ habit: Habit) async {
        do {
            try await env.api.deleteHabit(habit.id)
            habits.removeAll { $0.id == habit.id }
        } catch { self.error = error.localizedDescription }
    }

    private func add(_ habit: HabitNew) async -> String? {
        do {
            habits.append(try await env.api.addHabit(habit))
            return nil
        } catch { return error.localizedDescription }
    }
}

private struct NewHabitSheet: View {
    /// Returns an error message, or nil when saved.
    let save: (HabitNew) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var weekly = false
    @State private var perWeek = 3
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Gym", text: $name)
                Picker("How often", selection: $weekly) {
                    Text("Every day").tag(false)
                    Text("Some days a week").tag(true)
                }
                if weekly { Stepper("\(perWeek)× a week", value: $perWeek, in: 1...6) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("New habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            let habit = HabitNew(name: name.trimmingCharacters(in: .whitespaces),
                                                 cadence: .init(type: weekly ? "weekly" : "daily", perWeek: weekly ? perWeek : nil))
                            if let message = await save(habit) { error = message } else { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
