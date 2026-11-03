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

/// The week under the Body · Food switch: a ring a day, filled to the day's food score in its colour (green from 80,
/// the tint from 60, orange below), the date inside; the chosen day on a card, a day with nothing logged a dashed
/// circle, days to come faint. Tap a day to show it; swipe (or the arrows) for another week, keeping the weekday;
/// the date above opens a calendar for older days. It loads its own days from `GET /v1/food/days`.
struct FoodWeek: View {
    @Binding var day: Date
    let tint: Color
    /// Bumped by the page whenever its day reloads (a meal logged, fixed or deleted), so the rings catch up.
    var reload = 0

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var summaries: [String: FoodDaySummary] = [:]
    @State private var picking = false
    /// Which way the last week change went, for the slide.
    @State private var forward = true

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var weekStart: Date { calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day }
    private var days: [Date] { (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) } }
    private var isThisWeek: Bool { calendar.isDate(day, equalTo: today, toGranularity: .weekOfYear) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { picking = true } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        Image(systemName: "calendar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                .accessibilityHint("Opens a calendar")
                Spacer(minLength: 8)
                Button { move(-1) } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Week before")
                Button { move(1) } label: {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
                }
                .disabled(isThisWeek)
                .accessibilityLabel("Week after")
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .padding(.leading, 6)

            HStack(spacing: 4) {
                ForEach(days, id: \.self) { d in cell(d) }
            }
            .id(weekStart)
            .transition(.push(from: forward ? .trailing : .leading))
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.5, abs(v.translation.width) > 50
                        else { return }
                        move(v.translation.width < 0 ? 1 : -1)
                    }
            )
        }
        .clipped()
        .sensoryFeedback(.selection, trigger: day)
        .sheet(isPresented: $picking) {
            DayCalendar(day: $day).presentationDetents([.medium])
        }
        .task(id: "\(Wire.dayString(weekStart)) \(reload)") { await load() }
    }

    private func cell(_ d: Date) -> some View {
        let selected = calendar.isDate(d, inSameDayAs: day)
        let future = d > today
        let summary = summaries[Wire.dayString(d)]
        return Button {
            withAnimation(.snappy) { day = d }
        } label: {
            VStack(spacing: 6) {
                Text(d.formatted(.dateTime.weekday(.abbreviated)).prefix(3))
                    .font(.caption.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                DayRing(date: d, summary: summary, future: future, selected: selected, tint: tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .background(selected ? Theme.row : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(label(d, summary))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Today", "Yesterday" or "Monday 19 October".
    private var title: String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The date beside "Today" and "Yesterday".
    private var subtitle: String? {
        calendar.isDateInToday(day) || calendar.isDateInYesterday(day)
            ? day.formatted(.dateTime.weekday(.wide).day().month(.wide)) : nil
    }

    /// A week back or on, the same weekday, never past today.
    private func move(_ weeks: Int) {
        guard let next = calendar.date(byAdding: .day, value: 7 * weeks, to: day) else { return }
        forward = weeks > 0
        withAnimation(.snappy) { day = min(calendar.startOfDay(for: next), today) }
    }

    private func load() async {
        guard settings.isConfigured else { return }
        let start = weekStart
        let end = min(calendar.date(byAdding: .day, value: 6, to: start) ?? start, today)
        guard start <= end, let loaded = try? await env.api.foodDays(from: start, to: end) else { return }
        for summary in loaded { summaries[summary.date] = summary }
    }

    private func label(_ d: Date, _ summary: FoodDaySummary?) -> String {
        let name = d.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let summary, summary.meals > 0 else { return d > today ? name : "\(name), nothing logged" }
        return "\(name), \(summary.score.map { "score \($0)" } ?? "no score"), \(summary.totals.calories) kcal"
    }
}

/// One day of `FoodWeek`: its date in a ring filled to the score; dashed with nothing logged.
private struct DayRing: View {
    let date: Date
    let summary: FoodDaySummary?
    let future: Bool
    let selected: Bool
    let tint: Color

    private static let size: CGFloat = 38
    private static let line: CGFloat = 4.5

    var body: some View {
        ZStack {
            if future {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: Self.line)
            } else if let summary, summary.meals > 0 {
                Circle().stroke(tint.opacity(0.15), lineWidth: Self.line)
                if let score = summary.score {
                    Circle()
                        .trim(from: 0, to: max(Double(score) / 100, 0.02))
                        .stroke(Grade.scoreColor(score, tint: tint), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                Circle()
                    .inset(by: 1)
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3.5]))
            }
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 14, weight: selected ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(future ? Color.secondary.opacity(0.6) : Color.primary)
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: summary?.score)
    }
}

/// The meal's page: the photo across the top (the emoji without one), the name, time and quality; the numbers on one
/// card; what's in it, each food with its grade and processing; why the quality is what it is; Coach's notes; and a
/// way to ask Coach to fix it. Edit, in the corner, fixes the numbers by hand or deletes the meal.
struct MealPage: View {
    let meal: Meal
    let coach: Agent
    /// Each returns an error message, or nil when done.
    let save: (MealChanges) async -> String?
    let delete: () async -> String?
    /// Opens Coach's Food log chat (the sheet closes first).
    let askCoach: () -> Void
    /// Logs the same meal again now (an error message, or nil when done); nil hides it.
    var again: (() async -> String?)?
    @Environment(\.dismiss) private var dismiss
    @State private var loggingAgain = false
    @State private var againError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    top
                    numbers
                    foods
                    why
                    if !meal.notes.isEmpty {
                        DetailCard("Coach's notes") {
                            Text(meal.notes).font(.callout).textSelection(.enabled)
                        }
                    }
                    if let again {
                        Button {
                            Task {
                                loggingAgain = true
                                againError = await again()
                                loggingAgain = false
                                if againError == nil { dismiss() }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(coach.tint)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(loggingAgain ? "Logging…" : "Have it again").font(.subheadline.weight(.semibold))
                                    Text(againError ?? "The same, logged now: \(meal.calories) kcal")
                                        .font(.caption).foregroundStyle(againError == nil ? .secondary : Color.red)
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.primary)
                            .card(padding: 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CardPress())
                        .disabled(loggingAgain)
                    }
                    Button {
                        dismiss()
                        askCoach()
                    } label: {
                        HStack(spacing: 12) {
                            AgentMark(agent: coach, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Ask \(coach.name) to fix it").font(.subheadline.weight(.semibold))
                                Text("Wrong food, wrong amount: say it in the Food log chat")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .card(padding: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CardPress())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .pageColumn()
            }
            .background(Theme.grouped)
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle(meal.name)
            .toolbar {
                #if os(iOS) // the Mac's sheets have their own close button
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                #endif
                ToolbarItem(placement: .sheetDone) {
                    NavigationLink("Edit") {
                        MealEditForm(meal: meal, save: save, delete: delete, close: { dismiss() }).macPageBack()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// The photo, else the emoji; the name, when, and the quality pill.
    @ViewBuilder private var top: some View {
        if let photo = meal.photo {
            ServerPhoto(id: photo)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        HStack(alignment: .center, spacing: 14) {
            if meal.photo == nil { MealEmoji(emoji: meal.emoji, size: 64) }
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.name).font(.title2.weight(.bold)).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let when { Text(when).font(.subheadline).foregroundStyle(.secondary) }
                    if let quality = meal.quality {
                        let color = Grade.scoreColor(quality, tint: coach.tint)
                        Text("Quality \(quality)")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(color.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// "Today 13:10", "Yesterday 20:30", "Fri 30 Oct 12:45".
    private var when: String? {
        guard let date = meal.eatenDate else { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(time)"
    }

    /// Calories, protein, carbs and fat side by side; water and caffeine under them when there are any.
    private var numbers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                number("\(meal.calories)", "kcal", big: true)
                number("\(meal.proteinG) g", "Protein")
                number("\(meal.carbsG) g", "Carbs")
                number("\(meal.fatG) g", "Fat")
            }
            let drinks = [meal.waterMl > 0 ? "\(meal.waterMl) ml water" : nil,
                          meal.caffeineMg > 0 ? "\(meal.caffeineMg) mg caffeine" : nil].compactMap { $0 }
            if !drinks.isEmpty {
                Text(drinks.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func number(_ value: String, _ label: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(big ? .title2.weight(.bold) : .title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Each food with its grams, calories, Nutri-Score, processing and quality.
    @ViewBuilder private var foods: some View {
        if !meal.items.isEmpty {
            DetailCard("What's in it", padding: 0) {
                ForEach(Array(meal.items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Divider().padding(.leading, 16) }
                    MealItemRow(item: item).padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
        }
    }

    /// The meal's quality in its three parts.
    @ViewBuilder private var why: some View {
        if let parts = meal.qualityParts {
            DetailCard("Why \(meal.quality.map { "\($0)" } ?? "this score")",
                       note: "Judged as if all 2,000 kcal of the day were this meal, so plain chicken loses on fibre and fruit and veg, and a packaged yogurt with an A grade still loses on processing.") {
                QualityPartRow(name: "Nutrients", detail: "Fibre, fruit and veg, saturated fat, sugars and salt for its calories", part: parts.nutrients, tint: coach.tint)
                Divider().padding(.vertical, 10)
                QualityPartRow(name: "Processing", detail: "How little of it is ultra-processed (NOVA 4): full marks at 10% or less, none from 50%", part: parts.processing, tint: coach.tint)
                Divider().padding(.vertical, 10)
                QualityPartRow(name: "Food grades", detail: "Its foods' Nutri-Scores, by calories (A 100, B 75, C 50, D 25, E 0)", part: parts.grades, tint: coach.tint)
            }
        }
    }
}

/// Fixing what Coach estimated (name, time, numbers and notes), or deleting the meal. Behind Edit on the meal's page;
/// Save or Delete closes the whole sheet (`close`).
struct MealEditForm: View {
    let meal: Meal
    let save: (MealChanges) async -> String?
    let delete: () async -> String?
    let close: () -> Void
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

    init(meal: Meal, save: @escaping (MealChanges) async -> String?, delete: @escaping () async -> String?,
         close: @escaping () -> Void) {
        self.meal = meal
        self.save = save
        self.delete = delete
        self.close = close
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
        Form {
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
        .navigationTitle("Edit meal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

    private func run(_ action: @escaping () async -> String?) {
        working = true
        Task {
            if let message = await action() { error = message; working = false } else { close() }
        }
    }
}

/// A meal on its way in, at the top of Meals the moment it's sent: the photo (or the words), a shimmer over the
/// numbers still to come and Coach's Pebble thinking. It turns into the meal when Coach is done.
struct LoggingMealRow: View {
    let photo: UIImage?
    let text: String?
    let coach: Agent

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill().saturation(0.6).brightness(-0.08)
                } else {
                    Image(systemName: "text.cursor").font(.title3.weight(.semibold)).foregroundStyle(coach.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(coach.tint.opacity(0.14))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shimmering()
            VStack(alignment: .leading, spacing: 7) {
                Text(photo != nil ? "Reading your photo…" : text.map { "“\($0)”" } ?? "Working it out…")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SkeletonBar(width: 58, height: 9)
                    SkeletonBar(width: 44, height: 9)
                    SkeletonBar(width: 44, height: 9)
                }
                .shimmering()
            }
            Spacer(minLength: 0)
            LivePebble(mood: "thinking", size: 26, figure: coach.figure)
                .foregroundStyle(coach.tint)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coach.name) is reading your meal")
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
    var tint = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline.weight(.medium))
                Text("\(part.weight)%").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if let score = part.score {
                    Text("\(score)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Grade.scoreColor(score, tint: tint))
                } else {
                    Text("No data").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
