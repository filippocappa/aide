import SwiftUI

/// Habits: tick them off, add new ones, tap one to edit it, swipe to delete. The assistant can do the same from chat.
struct HabitsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var habits: [Habit] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var editing: Habit?

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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Button { Task { await toggle(habit) } } label: {
                                Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle").font(.title2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(habit.doneToday ? "Undo \(habit.name)" : "Mark \(habit.name) done")
                            Button { editing = habit } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(habit.name).font(.body.weight(.medium))
                                        Text(Self.detail(habit)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if habit.streak > 0 {
                                        Label("\(habit.streak)", systemImage: "flame.fill")
                                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.orange)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Edit")
                        }
                        if let history = habit.history { HabitGrid(done: Set(history)) }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.row)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { habits[$0] }
                    Task { for h in doomed { await remove(h) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add habit", systemImage: "plus") { adding = true }.disabled(!settings.isConfigured)
                }
            }
            .sheet(isPresented: $adding) { HabitSheet(habit: nil) { await add($0) } }
            .sheet(item: $editing) { habit in HabitSheet(habit: habit) { await update(habit, $0) } }
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

    /// "Every day · Strength from the Watch"
    private static func detail(_ habit: Habit) -> String {
        guard let workouts = habit.workouts, !workouts.isEmpty else { return habit.cadenceText }
        let names = workouts.contains("any") ? "Any workout" : workouts.map(WorkoutType.label).formatted(.list(type: .or))
        return "\(habit.cadenceText) · \(names) from the Watch"
    }

    private func update(_ habit: Habit, _ changes: HabitNew) async -> String? {
        do {
            let updated = try await env.api.updateHabit(habit.id, changes)
            if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = updated }
            return nil
        } catch APIError.server(let status, _) where status == 404 || status == 405 {
            return "The server can't edit habits yet."
        } catch { return error.localizedDescription }
    }

    private func add(_ habit: HabitNew) async -> String? {
        do {
            habits.append(try await env.api.addHabit(habit))
            return nil
        } catch { return error.localizedDescription }
    }
}

/// Adding a habit, or editing one (`habit` set).
private struct HabitSheet: View {
    let habit: Habit?
    /// Returns an error message, or nil when saved.
    let save: (HabitNew) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var weekly: Bool
    @State private var perWeek: Int
    @State private var workouts: Set<String>
    @State private var error: String?

    init(habit: Habit?, save: @escaping (HabitNew) async -> String?) {
        self.habit = habit
        self.save = save
        _name = State(initialValue: habit?.name ?? "")
        _weekly = State(initialValue: habit?.cadence.type == "weekly")
        _perWeek = State(initialValue: habit?.cadence.perWeek ?? 3)
        _workouts = State(initialValue: Set(habit?.workouts ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Gym", text: $name)
                    Picker("How often", selection: $weekly) {
                        Text("Every day").tag(false)
                        Text("Some days a week").tag(true)
                    }
                    if weekly { Stepper("\(perWeek)× a week", value: $perWeek, in: 1...6) }
                }
                Section {
                    NavigationLink {
                        WorkoutPicker(selection: $workouts)
                    } label: {
                        LabeledContent("Apple Watch workouts", value: summary)
                    }
                } footer: {
                    Text("A workout of one of these types, 10 minutes or longer, ticks the habit by itself.")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(habit == nil ? "New habit" : "Edit habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(habit == nil ? "Add" : "Save") {
                        Task {
                            let new = HabitNew(name: name.trimmingCharacters(in: .whitespaces),
                                               cadence: .init(type: weekly ? "weekly" : "daily", perWeek: weekly ? perWeek : nil),
                                               workouts: workouts.contains("any") ? ["any"] : workouts.sorted())
                            if let message = await save(new) { error = message } else { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summary: String {
        if workouts.isEmpty { return "None" }
        if workouts.contains("any") { return "Any" }
        return workouts.count == 1 ? WorkoutType.label(workouts.first!) : "\(workouts.count) types"
    }
}

/// Tick the workout types that count. "Any workout" covers them all.
private struct WorkoutPicker: View {
    @Binding var selection: Set<String>

    var body: some View {
        List(WorkoutType.all, id: \.id) { type in
            let on = selection.contains(type.id) || (type.id != "any" && selection.contains("any"))
            Button {
                if type.id == "any" {
                    selection = selection.contains("any") ? [] : ["any"]
                } else {
                    selection.remove("any")
                    if selection.contains(type.id) { selection.remove(type.id) } else { selection.insert(type.id) }
                }
            } label: {
                HStack {
                    Text(type.label).foregroundStyle(Color.primary)
                    Spacer()
                    if on { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
                .contentShape(Rectangle())
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The last 26 weeks, GitHub style: one column per week (Monday on top), a filled square for each
/// day it was done. The current week is the last column; days still to come are left out.
private struct HabitGrid: View {
    let done: Set<String>

    private static let weeks = 26
    private static let gap: CGFloat = 0.28 // of a square

    var body: some View {
        Canvas { context, size in
            let n = CGFloat(Self.weeks)
            let cell = size.width / (n + (n - 1) * Self.gap)
            let step = cell * (1 + Self.gap)
            var calendar = Calendar(identifier: .gregorian)
            calendar.firstWeekday = 2 // Monday
            let today = calendar.startOfDay(for: Date())
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return }
            for week in 0..<Self.weeks {
                for weekday in 0..<7 {
                    let offset = (week - (Self.weeks - 1)) * 7 + weekday
                    guard let day = calendar.date(byAdding: .day, value: offset, to: thisWeek), day <= today else { continue }
                    let rect = CGRect(x: CGFloat(week) * step, y: CGFloat(weekday) * step, width: cell, height: cell)
                    let shape = Path(roundedRect: rect, cornerRadius: cell * 0.25)
                    let isDone = done.contains(Wire.dayString(day))
                    context.fill(shape, with: .color(Theme.accent.opacity(isDone ? 1 : 0.1)))
                    if day == today { context.stroke(shape, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1) }
                }
            }
        }
        // 26 squares across, 7 down, with the same gap between them.
        .aspectRatio((26 + 25 * Self.gap) / (7 + 6 * Self.gap), contentMode: .fit)
        .accessibilityLabel("\(done.count) days done in the last 26 weeks")
    }
}
