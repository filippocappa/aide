import SwiftUI

/// What to eat and how the day went (docs/API.md, "Targets and the day score"): the card on top of Health → Food,
/// the day's page behind it, and the targets page (also in Settings) where Coach can propose them.

/// Nutri-Score's own colours, a to e.
enum Grade {
    static let all = ["a", "b", "c", "d", "e"]

    static func color(_ grade: String) -> Color {
        switch grade {
        case "a": Color(red: 0.01, green: 0.51, blue: 0.25)
        case "b": Color(red: 0.52, green: 0.73, blue: 0.18)
        case "c": Color(red: 0.92, green: 0.72, blue: 0.0)
        case "d": Color(red: 0.93, green: 0.51, blue: 0.0)
        default: Color(red: 0.90, green: 0.24, blue: 0.07)
        }
    }

    /// Green from 80, the agent's colour from 60, orange below.
    static func scoreColor(_ score: Int, tint: Color) -> Color {
        score >= 80 ? color("a") : score >= 60 ? tint : .orange
    }
}

/// The day's score in a ring.
struct ScoreRing: View {
    let score: Int?
    let tint: Color
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: size * 0.12)
            if let score {
                Circle()
                    .trim(from: 0, to: Double(score) / 100)
                    .stroke(Grade.scoreColor(score, tint: tint), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(score.map(String.init) ?? "–")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: score)
    }
}

/// On top of Health → Food: the day's score, what's left to eat and what a workout added. Taps open the day's page.
struct DayScoreCard: View {
    let day: FoodDay
    let isToday: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(score: day.score?.score, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let left = leftLine {
                    Text(left).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                if let bonus = Self.bonusLine(day.bonus) {
                    Label(bonus, systemImage: day.bonus.planned ? "calendar" : "figure.run")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(tint)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let score = day.score else { return isToday ? "Log a meal for today's score" : "Nothing logged" }
        let word = score.score >= 80 ? "Good day" : score.score >= 60 ? "Not bad" : "Off target"
        return score.final ? word : "\(word) so far"
    }

    /// "1,240 kcal left · P 60 · C 150 · F 30 g", or what's over.
    private var leftLine: String? {
        if !isToday, let score = day.score {
            return "Numbers \(score.numbers.map(String.init) ?? "–") · quality \(score.quality.map(String.init) ?? "–")"
        }
        guard let kcal = day.left.calories else { return nil }
        var parts = [kcal >= 0 ? "\(kcal.formatted()) kcal left" : "\((-kcal).formatted()) kcal over"]
        let macros = [("P", day.left.proteinG), ("C", day.left.carbsG), ("F", day.left.fatG)]
            .compactMap { name, g in g.map { "\(name) \(max($0, 0))" } }
        if !macros.isEmpty { parts.append(macros.joined(separator: " · ") + " g") }
        return parts.joined(separator: " · ")
    }

    /// "+656 kcal from your run", "+540 kcal for Corsa al Valentino".
    static func bonusLine(_ bonus: FoodBonus) -> String? {
        guard bonus.kcal > 0 else { return nil }
        if bonus.planned {
            return "+\(bonus.kcal) kcal for \(bonus.workouts.first?.title ?? "your run")"
        }
        let names = bonus.workouts.map { workoutName($0.type) }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "+\(bonus.kcal) kcal from your \(list)"
    }

    static func workoutName(_ type: String) -> String {
        switch type {
        case "run": "run"
        case "walk": "walk"
        case "hike": "hike"
        case "cycle": "ride"
        case "swim": "swim"
        case "strength": "workout"
        default: type.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The day's page: each target against what was eaten, the quality by grade, how the score is made, and the last
/// four weeks.
struct NutritionDayView: View {
    let day: FoodDay
    let tint: Color
    @EnvironmentObject private var env: AppEnvironment
    @State private var weeks: [FoodDaySummary] = []
    @State private var editing = false

    private var date: Date { Wire.day(day.date) ?? Date() }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ScoreRing(score: day.score?.score, tint: tint, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        if let score = day.score {
                            Text("Numbers \(score.numbers.map(String.init) ?? "–") · Quality \(score.quality.map(String.init) ?? "–")")
                                .font(.subheadline.weight(.semibold))
                            Text(score.final ? "The day's final score." : "So far: only going over costs until the day's done.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Nothing logged yet.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                target("Calories", eaten: day.totals.calories, goal: day.goals.calories, base: day.base.calories, unit: "kcal")
                target("Protein", eaten: day.totals.proteinG, goal: day.goals.proteinG, base: day.base.proteinG, unit: "g")
                target("Carbs", eaten: day.totals.carbsG, goal: day.goals.carbsG, base: day.base.carbsG, unit: "g")
                target("Fat", eaten: day.totals.fatG, goal: day.goals.fatG, base: day.base.fatG, unit: "g")
            } header: {
                Text("Targets")
            } footer: {
                if let bonus = DayScoreCard.bonusLine(day.bonus) {
                    Text(bonus + (day.bonus.planned ? ", from the calendar at your usual pace; the Watch's number takes over once it's done."
                                                    : ", mostly as carbs."))
                }
            }
            Section {
                QualityBars(grades: day.score?.grades ?? [:])
                    .padding(.vertical, 4)
            } header: {
                Text("Quality")
            } footer: {
                Text(qualityFooter)
            }
            Section {
                ScoreStrip(days: weeks, tint: tint)
                    .padding(.vertical, 4)
            } header: {
                Text("Last 4 weeks")
            }
            Section {
                Button("Targets") { editing = true }
            } footer: {
                Text("The score is 60% how close you came to the targets (calories within 10%, carbs and fat within 15%, protein at least the target) and 40% the quality of what you ate.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { NavigationStack { NutritionTargetsView(inSheet: true) } }
        .task {
            let start = Calendar.current.date(byAdding: .day, value: -27, to: date) ?? date
            weeks = (try? await env.api.foodDays(from: start, to: date)) ?? []
        }
    }

    private var qualityFooter: String {
        guard let score = day.score else { return "Each food's Nutri-Score, weighted by its calories." }
        if score.quality == nil {
            return "Not counted: only \(Int(score.graded * 100))% of the day's calories have a grade (it counts from half). Meals Coach logs from items get one."
        }
        return "Each food's Nutri-Score (Open Food Facts', or worked out from its numbers), weighted by its calories."
    }

    private func target(_ name: String, eaten: Int, goal: Int?, base: Int?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(goal.map { "\(eaten.formatted()) / \($0.formatted()) \(unit)" } ?? "\(eaten.formatted()) \(unit)")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if let goal, goal > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(Double(eaten) > Double(goal) * 1.1 && name != "Protein" ? Color.orange : tint)
                            .frame(width: geo.size.width * min(Double(eaten) / Double(goal), 1))
                    }
                }
                .frame(height: 6)
                if let base, base != goal {
                    Text("\(base.formatted()) on a rest day").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Calories by Nutri-Score grade, one bar each.
struct QualityBars: View {
    let grades: [String: Int]

    var body: some View {
        let top = max(grades.values.max() ?? 0, 1)
        VStack(spacing: 7) {
            ForEach(Grade.all, id: \.self) { g in
                let kcal = grades[g] ?? 0
                HStack(spacing: 10) {
                    Text(g.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Grade.color(g), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    GeometryReader { geo in
                        Capsule().fill(Grade.color(g).opacity(kcal > 0 ? 1 : 0.15))
                            .frame(width: max(6, geo.size.width * Double(kcal) / Double(top)))
                    }
                    .frame(height: 8)
                    Text("\(kcal) kcal").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Grade.all.map { "\($0.uppercased()) \(grades[$0] ?? 0) kcal" }.joined(separator: ", "))
    }
}

/// The days' scores as small columns, oldest first; a gap where nothing was logged.
struct ScoreStrip: View {
    let days: [FoodDaySummary]
    let tint: Color

    var body: some View {
        let scored = days.compactMap(\.score)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.date) { d in
                    VStack {
                        Spacer(minLength: 0)
                        if let s = d.score {
                            RoundedRectangle(cornerRadius: 2).fill(Grade.scoreColor(s, tint: tint))
                                .frame(height: max(4, 54 * Double(s) / 100))
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.12)).frame(height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 54)
            Text(scored.isEmpty ? "No scores yet."
                 : "Average \(scored.reduce(0, +) / scored.count) over \(scored.count) day\(scored.count == 1 ? "" : "s").")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Nutrition targets: the rest-day base, what a workout adds, the profile (from Apple Health the first
/// time), and Coach's proposal from all of it.
struct NutritionTargetsView: View {
    var inSheet = false
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var health: HealthService
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: FoodTargets?
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var workouts = WorkoutTargets()
    @State private var weight = ""
    @State private var height = ""
    @State private var age = ""
    @State private var sex = ""
    @State private var goal = "keep"
    @State private var proposing = false
    @State private var proposal: TargetsProposal?
    @State private var error: String?
    @State private var saving = false
    @State private var filledFromHealth = false

    var body: some View {
        Form {
            if loaded == nil, error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                Section {
                    NumberField(label: "Calories", unit: "kcal", text: $calories, placeholder: "None")
                    NumberField(label: "Protein", unit: "g", text: $protein, placeholder: "None")
                    NumberField(label: "Carbs", unit: "g", text: $carbs, placeholder: "None")
                    NumberField(label: "Fat", unit: "g", text: $fat, placeholder: "None")
                } header: {
                    Text("A rest day")
                } footer: {
                    Text("Leave one empty for no target. Coach can change them in chat too: \"aim for 140 g protein\".")
                }
                Section {
                    Toggle("Add what workouts burn", isOn: $workouts.on)
                    if workouts.on {
                        LabeledContent("Of the Watch's kcal") {
                            Stepper("\(Int((workouts.share * 100).rounded()))%", value: $workouts.share, in: 0...1.5, step: 0.05)
                                .monospacedDigit()
                        }
                        LabeledContent("As carbs") {
                            Stepper("\(workouts.carbsPct)%", value: $workouts.carbsPct, in: 0...100, step: 5)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Workout days")
                } footer: {
                    Text(workouts.on ? "A 650 kcal run adds \(Int(650 * workouts.share)) kcal: \(workouts.carbsPct)% as carbs, the rest as fat. A run in your calendar counts before it happens, at your usual pace."
                                     : "Every day has the rest-day targets.")
                }
                Section {
                    DecimalField(label: "Weight", unit: "kg", text: $weight)
                    NumberField(label: "Height", unit: "cm", text: $height, placeholder: "–")
                    NumberField(label: "Age", unit: "", text: $age, placeholder: "–")
                    Picker("Sex", selection: $sex) {
                        Text("–").tag("")
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                    }
                    Picker("Goal", selection: $goal) {
                        Text("Lose weight").tag("lose")
                        Text("Keep it").tag("keep")
                        Text("Gain").tag("gain")
                    }
                } header: {
                    Text("You")
                } footer: {
                    if filledFromHealth { Text("Filled in from Apple Health. Save to keep it.") }
                }
                Section {
                    if let proposal {
                        ProposalView(proposal: proposal, current: currentBase)
                        Button("Use these") { use(proposal) }
                            .font(.body.weight(.semibold))
                    }
                    Button {
                        Task { await propose() }
                    } label: {
                        HStack {
                            Label(proposal == nil ? "Ask Coach to propose" : "Ask again", systemImage: "wand.and.stars")
                            if proposing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(proposing)
                } footer: {
                    Text("Coach looks at you, 60 days of Apple Health (runs, pace, VO2 max, weight) and what you've eaten. Nothing changes until you save.")
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Nutrition targets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(loaded == nil || saving)
            }
        }
        .task { await load() }
    }

    private var currentBase: FoodGoals {
        FoodGoals(calories: Self.number(calories), proteinG: Self.number(protein), carbsG: Self.number(carbs),
                  fatG: Self.number(fat))
    }

    private func load() async {
        guard settings.isConfigured else { error = "Set up the server first."; return }
        do {
            let t = try await env.api.foodTargets()
            loaded = t
            calories = t.base.calories.map(String.init) ?? ""
            protein = t.base.proteinG.map(String.init) ?? ""
            carbs = t.base.carbsG.map(String.init) ?? ""
            fat = t.base.fatG.map(String.init) ?? ""
            workouts = t.workouts
            var p = t.profile
            if p.weightKg == nil, p.heightCm == nil, p.age == nil, p.sex == nil { // the first time: from Apple Health
                let h = await health.profile()
                (p.weightKg, p.heightCm, p.age, p.sex) = (h.weightKg, h.heightCm, h.age, h.sex)
                filledFromHealth = h != FoodProfile()
            }
            weight = p.weightKg.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? ""
            height = p.heightCm.map(String.init) ?? ""
            age = p.age.map(String.init) ?? ""
            sex = p.sex ?? ""
            goal = p.goal ?? "keep"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var targets: FoodTargets {
        var p = FoodProfile()
        p.weightKg = Double(weight.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        p.heightCm = Self.number(height)
        p.age = Self.number(age)
        p.sex = sex.isEmpty ? nil : sex
        p.goal = goal
        return FoodTargets(base: currentBase, workouts: workouts, profile: p)
    }

    /// Saves the profile first, so Coach proposes from what's on screen.
    private func propose() async {
        proposing = true
        error = nil
        defer { proposing = false }
        do {
            var current = targets
            if let loaded { current.base = loaded.base; current.workouts = loaded.workouts } // only the profile
            loaded = try await env.api.saveFoodTargets(current)
            filledFromHealth = false
            withAnimation { proposal = nil }
            let got = try await env.api.proposeFoodTargets()
            withAnimation { proposal = got }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func use(_ p: TargetsProposal) {
        calories = p.base.calories.map(String.init) ?? ""
        protein = p.base.proteinG.map(String.init) ?? ""
        carbs = p.base.carbsG.map(String.init) ?? ""
        fat = p.base.fatG.map(String.init) ?? ""
        workouts = WorkoutTargets(on: true, share: p.workouts.share, carbsPct: p.workouts.carbsPct)
        withAnimation { proposal = nil }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            loaded = try await env.api.saveFoodTargets(targets)
            filledFromHealth = false
            error = nil
            if inSheet { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Empty, zero or not a number: none.
    private static func number(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Coach's proposal next to the numbers now, and why.
private struct ProposalView: View {
    let proposal: TargetsProposal
    let current: FoodGoals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Now").font(.caption).foregroundStyle(.secondary)
                    Text("Coach").font(.caption.weight(.semibold))
                }
                row("Calories", current.calories, proposal.base.calories, "kcal")
                row("Protein", current.proteinG, proposal.base.proteinG, "g")
                row("Carbs", current.carbsG, proposal.base.carbsG, "g")
                row("Fat", current.fatG, proposal.base.fatG, "g")
                GridRow {
                    Text("Workouts").font(.subheadline)
                    Text("")
                    Text("\(Int((proposal.workouts.share * 100).rounded()))%, \(proposal.workouts.carbsPct)% carbs")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .monospacedDigit()
            if !proposal.why.isEmpty {
                Text(proposal.why).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ name: String, _ now: Int?, _ new: Int?, _ unit: String) -> some View {
        GridRow {
            Text(name).font(.subheadline)
            Text(now.map { "\($0) \(unit)" } ?? "–").font(.subheadline).foregroundStyle(.secondary)
            Text(new.map { "\($0) \(unit)" } ?? "–").font(.subheadline.weight(.semibold))
        }
    }
}

/// A form row with a number that may have a decimal ("74,5" or "74.5").
private struct DecimalField: View {
    let label: String
    let unit: String
    @Binding var text: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("–", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
