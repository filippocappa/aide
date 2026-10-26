import SwiftUI
import WidgetKit

/// A habit: tick it (or, for a limit habit, count one more), tap the rest to edit it, and its last 26 weeks
/// underneath when `showsGrid`.
struct HabitRow: View {
    let habit: Habit
    let toggle: () -> Void
    /// A limit habit's +1 (1) or take one back (-1).
    var count: (Int) -> Void = { _ in }
    let edit: () -> Void
    var showsGrid = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if habit.isLimit {
                    LimitCounter(habit: habit, count: count)
                } else {
                    Button(action: toggle) {
                        Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(habit.doneToday ? "Undo \(habit.name)" : "Mark \(habit.name) done")
                }
                Button(action: edit) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.name).font(.body.weight(.medium)).foregroundStyle(Color.primary)
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
                .buttonStyle(.borderless)
                .accessibilityHint("Edit")
            }
            if showsGrid, let history = habit.history { HabitGrid(done: Set(history)) }
        }
        .padding(.vertical, 4)
    }

    /// "Every day · Strength from the Watch", "3× a week · 2 so far", "At most 5 a day · 2 today".
    static func detail(_ habit: Habit) -> String {
        var parts = [habit.cadenceText]
        if habit.isWeekly { parts.append("\(habit.thisWeek) so far") }
        if habit.isLimit {
            let n = habit.count ?? 0
            parts.append(n > (habit.cadence.max ?? 0) ? "\(n) today, over" : "\(n) today")
        }
        if let workouts = habit.workouts, !workouts.isEmpty {
            let names = workouts.contains("any") ? "Any workout" : workouts.map(WorkoutType.label).formatted(.list(type: .or))
            parts.append("\(names) from the Watch")
        }
        if let food = habit.food { parts.append("\(FoodHabit.label(food)) ticks it") }
        return parts.joined(separator: " · ")
    }
}

/// A limit habit's day so far, "2 of 5", between taking one back and adding one. One tap on + logs one.
struct LimitCounter: View {
    let habit: Habit
    let count: (Int) -> Void

    private var n: Int { habit.count ?? 0 }
    private var most: Int { habit.cadence.max ?? 1 }
    private var over: Bool { n > most }

    var body: some View {
        HStack(spacing: 6) {
            Button { count(-1) } label: {
                Image(systemName: "minus").font(.caption.weight(.bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(n == 0)
            .accessibilityLabel("Take one back")
            Text("\(n)/\(most)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(over ? Color.red : Color.primary)
                .frame(minWidth: 34)
                .accessibilityLabel("\(n) of \(most) today")
            Button { count(1) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(over ? Color.red : Theme.accent, in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Log one \(habit.name)")
        }
    }
}

/// Every habit with its grid: tick, count, edit, add and delete. Opened from Today.
struct HabitsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Binding var habits: [Habit]
    @State private var error: String?
    @State private var adding = false
    @State private var editing: Habit?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    .listRowBackground(Theme.row)
            }
            Section {
                if habits.isEmpty {
                    Text("No habits yet. Tap + to add one, or tell Coach in chat: \"add a gym habit, three times a week\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(habits) { habit in
                    HabitRow(habit: habit, toggle: { Task { await HabitActions.toggle(habit, in: $habits, env: env, error: $error) } },
                             count: { n in Task { await HabitActions.count(habit, n, in: $habits, env: env, error: $error) } },
                             edit: { editing = habit })
                }
                .onDelete { offsets in
                    let doomed = offsets.map { habits[$0] }
                    Task {
                        for h in doomed {
                            do { try await env.api.deleteHabit(h.id); habits.removeAll { $0.id == h.id } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            } footer: {
                Text("Habits are what you always do. What this day, week or month is about goes in objectives.")
            }
            .listRowBackground(Theme.row)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Habits")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add habit")
                    .disabled(!settings.isConfigured)
            }
        }
        .sheet(isPresented: $adding) {
            HabitSheet(habit: nil) { new in
                do { habits.append(try await env.api.addHabit(new)); return nil } catch { return error.localizedDescription }
            }
        }
        .sheet(item: $editing) { habit in
            HabitSheet(habit: habit) { changes in
                do {
                    let updated = try await env.api.updateHabit(habit.id, changes)
                    if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = updated }
                    return nil
                } catch { return error.localizedDescription }
            }
        }
    }
}

/// Ticking and counting a habit in a list of them, shared by Today and the Habits screen.
@MainActor
enum HabitActions {
    static func toggle(_ habit: Habit, in habits: Binding<[Habit]>, env: AppEnvironment, error problem: Binding<String?>) async {
        do { replace(try await env.api.checkHabit(habit.id, done: !habit.doneToday), in: habits); problem.wrappedValue = nil }
        catch { problem.wrappedValue = error.localizedDescription }
    }

    static func count(_ habit: Habit, _ add: Int, in habits: Binding<[Habit]>, env: AppEnvironment,
                      error problem: Binding<String?>) async {
        if add > 0 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        do { replace(try await env.api.countHabit(habit.id, add: add), in: habits); problem.wrappedValue = nil }
        catch { problem.wrappedValue = error.localizedDescription }
    }

    static func replace(_ habit: Habit, in habits: Binding<[Habit]>) {
        if let i = habits.wrappedValue.firstIndex(where: { $0.id == habit.id }) { habits.wrappedValue[i] = habit }
        WidgetCenter.shared.reloadTimelines(ofKind: "Health")
        WidgetCenter.shared.reloadTimelines(ofKind: "Objectives") // a check-in can tick an objective
    }
}

/// Adding a habit, or editing one (`habit` set).
struct HabitSheet: View {
    let habit: Habit?
    /// Returns an error message, or nil when saved.
    let save: (HabitNew) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// "daily", "weekly" or "limit".
    @State private var kind: String
    @State private var perWeek: Int
    @State private var most: Int
    @State private var workouts: Set<String>
    /// "" for none.
    @State private var food: String
    @State private var error: String?

    init(habit: Habit?, save: @escaping (HabitNew) async -> String?) {
        self.habit = habit
        self.save = save
        _name = State(initialValue: habit?.name ?? "")
        _kind = State(initialValue: habit?.cadence.type ?? "daily")
        _perWeek = State(initialValue: habit?.cadence.perWeek ?? 3)
        _most = State(initialValue: habit?.cadence.max ?? 5)
        _workouts = State(initialValue: Set(habit?.workouts ?? []))
        _food = State(initialValue: habit?.food ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == "limit" ? "Name, e.g. Coffee" : "Name, e.g. Gym", text: $name)
                    Picker("How often", selection: $kind) {
                        Text("Every day").tag("daily")
                        Text("Some days a week").tag("weekly")
                        Text("A limit a day").tag("limit")
                    }
                    if kind == "weekly" { Stepper("\(perWeek)× a week", value: $perWeek, in: 1...6) }
                    if kind == "limit" { Stepper("At most \(most) a day", value: $most, in: 1...100) }
                } footer: {
                    if kind == "limit" {
                        Text("Log each one with +, from a widget, Control Center or the Action Button. A day under the limit at midnight counts as done.")
                    }
                }
                if kind != "limit" {
                    Section {
                        NavigationLink {
                            WorkoutPicker(selection: $workouts)
                        } label: {
                            LabeledContent("Apple Watch workouts", value: summary)
                        }
                        Picker("Food log", selection: $food) {
                            Text("None").tag("")
                            ForEach(FoodHabit.all, id: \.id) { Text($0.label).tag($0.id) }
                        }
                    } header: {
                        Text("Ticks itself")
                    } footer: {
                        Text("A workout of one of these types, 10 minutes or longer, ticks the habit by itself. So does the food log: a day with a meal logged, or at a goal.")
                    }
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
                            let limit = kind == "limit"
                            let new = HabitNew(name: name.trimmingCharacters(in: .whitespaces),
                                               cadence: .init(type: kind, perWeek: kind == "weekly" ? perWeek : nil,
                                                              max: limit ? most : nil),
                                               workouts: limit ? [] : workouts.contains("any") ? ["any"] : workouts.sorted(),
                                               food: limit || food.isEmpty ? nil : food)
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
