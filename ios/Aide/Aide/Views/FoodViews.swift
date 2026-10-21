import SwiftUI

/// A meal on one line: its photo, name and macros, then calories and time. In the Health tab and in chat cards.
struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealThumb(photo: meal.photo)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name).lineLimit(2)
                Text(Self.macros(meal)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(meal.calories) kcal").font(.subheadline.weight(.semibold)).monospacedDigit()
                if let time = meal.eatenDate {
                    Text(time.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "P 20 g · C 110 g · F 15 g"
    static func macros(_ meal: Meal) -> String { "P \(meal.proteinG) g · C \(meal.carbsG) g · F \(meal.fatG) g" }
}

/// The meal's photo, or a fork and knife without one.
struct MealThumb: View {
    let photo: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let photo {
                ServerPhoto(id: photo)
            } else {
                Color.secondary.opacity(0.12)
                    .overlay { Image(systemName: "fork.knife").font(.system(size: size * 0.38)).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

/// The day's calories: a ring filling up to the goal, or just the number without one.
struct CalorieRing: View {
    let eaten: Int
    let goal: Int?
    let tint: Color

    private static let line: CGFloat = 11

    var body: some View {
        ZStack {
            if let goal, goal > 0 {
                Circle().stroke(tint.opacity(0.15), lineWidth: Self.line)
                Circle()
                    .trim(from: 0, to: min(Double(eaten) / Double(goal), 1))
                    .stroke(eaten > goal ? Color.orange : tint, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(eaten)").font(.title2.bold()).monospacedDigit().contentTransition(.numericText())
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 118, height: 118)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: eaten)
        .accessibilityElement(children: .combine)
    }

    /// "kcal", "420 left" or "120 over".
    private var caption: String {
        guard let goal, goal > 0 else { return "kcal" }
        return eaten <= goal ? "\(goal - eaten) left" : "\(eaten - goal) over"
    }
}

/// One macro: grams eaten against its goal, or, without a goal, its share of the day's calories.
struct MacroBar: View {
    let name: String
    let grams: Int
    let goal: Int?
    /// Of the day's calories (4 kcal per gram of protein or carbs, 9 of fat), for the bar without a goal.
    let share: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.caption.weight(.semibold))
                Spacer()
                Text(goal.map { "\(grams) / \($0) g" } ?? "\(grams) g")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.15))
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: grams)
        .accessibilityElement(children: .combine)
    }

    private var fraction: Double {
        guard let goal, goal > 0 else { return min(max(share, 0), 1) }
        return min(Double(grams) / Double(goal), 1)
    }
}

/// The ring and the three macro bars for a day.
struct FoodSummary: View {
    let totals: FoodTotals
    let goals: FoodGoals
    let tint: Color

    var body: some View {
        HStack(spacing: 20) {
            CalorieRing(eaten: totals.calories, goal: goals.calories, tint: tint)
            VStack(spacing: 12) {
                MacroBar(name: "Protein", grams: totals.proteinG, goal: goals.proteinG, share: share(totals.proteinG, 4), tint: tint)
                MacroBar(name: "Carbs", grams: totals.carbsG, goal: goals.carbsG, share: share(totals.carbsG, 4), tint: tint)
                MacroBar(name: "Fat", grams: totals.fatG, goal: goals.fatG, share: share(totals.fatG, 9), tint: tint)
            }
        }
    }

    private func share(_ grams: Int, _ kcalPerGram: Double) -> Double {
        totals.calories > 0 ? Double(grams) * kcalPerGram / Double(totals.calories) : 0
    }
}

/// The last seven days, today on the right. Each has a small bar for what was eaten against the calorie goal
/// (a dot without a goal) once something's logged.
struct WeekStrip: View {
    let days: [Date]
    let summaries: [String: FoodDaySummary]
    let goal: Int?
    let tint: Color
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let selected = Calendar.current.isDate(day, inSameDayAs: selection)
                Button { selection = day } label: {
                    VStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .opacity(0.7)
                        Text(day.formatted(.dateTime.day()))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        mark(summaries[Wire.dayString(day)], selected: selected)
                    }
                    .foregroundStyle(selected ? Theme.onAccent : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selected ? Theme.accent : Theme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy, value: selection)
    }

    @ViewBuilder private func mark(_ summary: FoodDaySummary?, selected: Bool) -> some View {
        let color = selected ? Theme.onAccent : tint
        if let summary, summary.meals > 0 {
            if let goal, goal > 0 {
                let fraction = min(Double(summary.totals.calories) / Double(goal), 1)
                Capsule().fill(color.opacity(0.25))
                    .overlay(alignment: .leading) {
                        Capsule().fill(summary.totals.calories > goal ? Color.orange : color).frame(width: 18 * fraction)
                    }
                    .frame(width: 18, height: 4)
            } else {
                Circle().fill(color).frame(width: 5, height: 5).frame(height: 4)
            }
        } else {
            Color.clear.frame(width: 18, height: 4)
        }
    }

    private func label(_ day: Date) -> String {
        let name = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let summary = summaries[Wire.dayString(day)], summary.meals > 0 else { return name }
        return "\(name), \(summary.totals.calories) kcal"
    }
}

/// Fixing what Coach estimated: name, time, numbers and notes, or deleting the meal.
struct MealSheet: View {
    let meal: Meal
    /// Each returns an error message, or nil when done.
    let save: (MealChanges) async -> String?
    let delete: () async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var time: Date
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var notes: String
    @State private var error: String?
    @State private var working = false
    @State private var confirmDelete = false

    init(meal: Meal, save: @escaping (MealChanges) async -> String?, delete: @escaping () async -> String?) {
        self.meal = meal
        self.save = save
        self.delete = delete
        _name = State(initialValue: meal.name)
        _time = State(initialValue: meal.eatenDate ?? Date())
        _calories = State(initialValue: String(meal.calories))
        _protein = State(initialValue: String(meal.proteinG))
        _carbs = State(initialValue: String(meal.carbsG))
        _fat = State(initialValue: String(meal.fatG))
        _notes = State(initialValue: meal.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let photo = meal.photo {
                    Section {
                        ServerPhoto(id: photo, fit: true)
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("Name", text: $name)
                    DatePicker("Time", selection: $time, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    NumberField(label: "Calories", unit: "kcal", text: $calories)
                    NumberField(label: "Protein", unit: "g", text: $protein)
                    NumberField(label: "Carbs", unit: "g", text: $carbs)
                    NumberField(label: "Fat", unit: "g", text: $fat)
                } footer: {
                    Text("Coach's estimate. Change anything that's off.")
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Button("Delete meal", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete \(meal.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { run { await delete() } }
                        }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let changes = MealChanges(
                            name: name.trimmingCharacters(in: .whitespaces), eatenAt: Wire.local(time),
                            calories: Int(calories) ?? meal.calories, proteinG: Int(protein) ?? meal.proteinG,
                            carbsG: Int(carbs) ?? meal.carbsG, fatG: Int(fat) ?? meal.fatG,
                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                        run { await save(changes) }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(working)
        }
        .presentationDetents([.large])
    }

    private func run(_ action: @escaping () async -> String?) {
        working = true
        Task {
            if let message = await action() { error = message; working = false } else { dismiss() }
        }
    }
}

/// Daily calories and macros to aim for; an empty field is no goal.
struct FoodGoalsSheet: View {
    /// Returns an error message, or nil when saved.
    let save: (FoodGoals) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var error: String?

    init(goals: FoodGoals, save: @escaping (FoodGoals) async -> String?) {
        self.save = save
        _calories = State(initialValue: goals.calories.map(String.init) ?? "")
        _protein = State(initialValue: goals.proteinG.map(String.init) ?? "")
        _carbs = State(initialValue: goals.carbsG.map(String.init) ?? "")
        _fat = State(initialValue: goals.fatG.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NumberField(label: "Calories", unit: "kcal", text: $calories, placeholder: "None")
                    NumberField(label: "Protein", unit: "g", text: $protein, placeholder: "None")
                    NumberField(label: "Carbs", unit: "g", text: $carbs, placeholder: "None")
                    NumberField(label: "Fat", unit: "g", text: $fat, placeholder: "None")
                } footer: {
                    Text("Leave one empty for no goal. Coach can set them too: \"aim for 140 g protein\".")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Food goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let goals = FoodGoals(calories: Self.number(calories), proteinG: Self.number(protein),
                                                  carbsG: Self.number(carbs), fatG: Self.number(fat))
                            if let message = await save(goals) { error = message } else { dismiss() }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Empty, zero or not a number: no goal.
    private static func number(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// A form row with a whole number on the right and its unit after it.
private struct NumberField: View {
    let label: String
    let unit: String
    @Binding var text: String
    var placeholder = "0"

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(placeholder, text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
