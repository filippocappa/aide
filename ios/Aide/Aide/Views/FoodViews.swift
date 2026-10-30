import SwiftUI

/// A meal on one line: its emoji, name and macros (a camera when it has a photo, which shows only on its page), then
/// its quality, calories and time. In the Health tab and in chat cards.
struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealEmoji(emoji: meal.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name).lineLimit(2)
                HStack(spacing: 4) {
                    Text(Self.macros(meal)).monospacedDigit()
                    if meal.photo != nil {
                        Image(systemName: "camera.fill").accessibilityLabel("Has a photo")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let quality = meal.quality {
                QualityBadge(score: quality)
            }
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

/// One food in a meal: name, grams and calories, its Nutri-Score letter and "Ultra-processed" when it's NOVA 4, and
/// its quality.
struct MealItemRow: View {
    let item: MealItem

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    Text([item.grams.map { "\($0) g" }, "\(item.kcal) kcal"].compactMap { $0 }.joined(separator: " · "))
                        .monospacedDigit()
                    if let grade = item.grade {
                        Text(grade.uppercased())
                            .font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Grade.color(grade), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .accessibilityLabel("Nutri-Score \(grade.uppercased())")
                    }
                    if item.nova == 4 {
                        Text("Ultra-processed").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let quality = item.quality { QualityBadge(score: quality) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The meal's emoji on a soft tile.
struct MealEmoji: View {
    let emoji: String
    var size: CGFloat = 44

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
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
                if let drinks {
                    Text(drinks).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// "1.0 L water · 65 mg caffeine", or nil when there's neither.
    private var drinks: String? {
        let parts = [
            totals.waterMl > 0 ? (totals.waterMl >= 1000 ? String(format: "%.1f L water", Double(totals.waterMl) / 1000)
                                                         : "\(totals.waterMl) ml water") : nil,
            totals.caffeineMg > 0 ? "\(totals.caffeineMg) mg caffeine" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// The meal's page: its foods with their quality, then fixing what Coach estimated (name, time, numbers and notes),
/// or deleting the meal.
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
    @State private var water: String
    @State private var caffeine: String
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
        _water = State(initialValue: String(meal.waterMl))
        _caffeine = State(initialValue: String(meal.caffeineMg))
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
                foodsSection
                Section {
                    TextField("Name", text: $name)
                    DatePicker("Time", selection: $time, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    NumberField(label: "Calories", unit: "kcal", text: $calories)
                    NumberField(label: "Protein", unit: "g", text: $protein)
                    NumberField(label: "Carbs", unit: "g", text: $carbs)
                    NumberField(label: "Fat", unit: "g", text: $fat)
                    NumberField(label: "Water", unit: "ml", text: $water)
                    NumberField(label: "Caffeine", unit: "mg", text: $caffeine)
                } footer: {
                    Text("Coach's estimate. Change anything that's off; Apple Health gets the new numbers.")
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
                            waterMl: Int(water) ?? meal.waterMl, caffeineMg: Int(caffeine) ?? meal.caffeineMg,
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

    /// Each food with its grams, calories, Nutri-Score and processing, and its quality; the meal's quality on top.
    @ViewBuilder private var foodsSection: some View {
        if !meal.items.isEmpty {
            Section {
                ForEach(Array(meal.items.enumerated()), id: \.offset) { _, item in MealItemRow(item: item) }
            } header: {
                HStack {
                    Text("What's in it")
                    Spacer()
                    if let quality = meal.quality {
                        Text("Quality \(quality)").monospacedDigit()
                            .foregroundStyle(Grade.scoreColor(quality, tint: Theme.accent))
                    }
                }
            } footer: {
                Text("Quality is 0–100: the meal's fibre, fruit and veg, saturated fat, sugars and salt for its calories (half), how little of it is ultra-processed (a quarter) and its foods' Nutri-Scores (a quarter).")
            }
            if let parts = meal.qualityParts {
                Section {
                    QualityPartRow(name: "Nutrients", detail: "Fibre, fruit and veg, saturated fat, sugars and salt, per 2,000 kcal of this meal", part: parts.nutrients)
                    QualityPartRow(name: "Processing", detail: "The share of its calories that's ultra-processed (NOVA 4): full marks at 10% or less, none from 50%", part: parts.processing)
                    QualityPartRow(name: "Food grades", detail: "Its foods' Nutri-Scores, by calories (A 100, B 75, C 50, D 25, E 0)", part: parts.grades)
                } header: {
                    Text("Why \(meal.quality.map { "\($0)" } ?? "this score")")
                } footer: {
                    Text("A meal of one food is judged as if all 2,000 kcal of the day were that food, so plain chicken has no fibre or fruit and veg and loses points there, and a packaged yogurt with an A grade still loses on processing.")
                }
            }
        }
    }

    private func run(_ action: @escaping () async -> String?) {
        working = true
        Task {
            if let message = await action() { error = message; working = false } else { dismiss() }
        }
    }
}

/// After photos are picked or taken: what they show, in a few words if you like, then Log sends both.
struct MealPhotosSheet: View {
    let photos: [PickedPhoto]
    let log: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(photos) { photo in
                                Image(uiImage: photo.preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: photos.count == 1 ? 220 : 140, height: photos.count == 1 ? 220 : 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Section {
                    TextField("Carbonara, about half the plate, and a coke", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focused)
                } header: {
                    Text("What is it?")
                } footer: {
                    if photos.contains(where: { !$0.barcodes.isEmpty }) {
                        Text("Barcode read: Coach uses the packet's real numbers. Say how much you had.")
                    } else {
                        Text("Optional. Amounts, brands, what's hidden (oil, sugar in the coffee) make the numbers better.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Log a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        log(words.isEmpty ? nil : words)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A form row with a whole number on the right and its unit after it.
struct NumberField: View {
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

/// One part of a meal's quality: its name, what it measures, its score and share.
private struct QualityPartRow: View {
    let name: String
    let detail: String
    let part: MealQualityParts.Part

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline.weight(.medium))
                Text("\(part.weight)%").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if let score = part.score {
                    Text("\(score)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Grade.scoreColor(score, tint: Theme.accent))
                } else {
                    Text("No data").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
