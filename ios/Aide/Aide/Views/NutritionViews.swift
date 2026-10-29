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
                if let hint = day.score?.hint {
                    Text(hint).font(.footnote.weight(.medium)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let score = day.score else {
            if !day.meals.isEmpty { return "Set your targets for a score" } // eaten, but nothing to score it against
            return isToday ? "Log a meal for today's score" : "Nothing logged"
        }
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
            if let score = day.score, score.parts != nil {
                Section {
                    ForEach(QualityLine.nutrients(score), id: \.name) { QualityLineRow(line: $0, tint: tint) }
                } header: {
                    partHeader("Nutrients", score.parts?.nutrients)
                } footer: {
                    Text("Half the quality. Fibre and fruit & veg count once the day's over, the limits as soon as they're passed. Each needs data on half the day's calories; meals Coach logs from items have it.")
                }
                Section {
                    QualityLineRow(line: QualityLine.processing(score), tint: tint)
                } header: {
                    partHeader("Processing", score.parts?.processing)
                } footer: {
                    Text("A quarter of the quality: the share of calories from ultra-processed foods (NOVA 4: packaged snacks, soft drinks, most sweets and ready meals). Full marks at 10% or less, none from 50%.")
                }
            }
            Section {
                QualityBars(grades: day.score?.grades ?? [:])
                    .padding(.vertical, 4)
            } header: {
                if day.score?.parts != nil {
                    partHeader("Food grades", day.score?.parts?.grades)
                } else {
                    Text("Quality")
                }
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
                Text("The score is 60% how close you came to the targets (calories within 10%, carbs and fat within 15%, protein at least the target) and 40% the quality of what you ate: the day's nutrients (half), how processed it was and each food's Nutri-Score (a quarter each).")
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

    private func partHeader(_ name: String, _ score: Int?) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(score.map(String.init) ?? "–").monospacedDigit()
                .foregroundStyle(score.map { Grade.scoreColor($0, tint: tint) } ?? Color.secondary)
        }
    }

    private var qualityFooter: String {
        guard let score = day.score else { return "Each food's Nutri-Score, weighted by its calories." }
        if score.quality == nil {
            return "Not counted: only \(Int(score.graded * 100))% of the day's calories have a grade (it counts from half). Meals Coach logs from items get one."
        }
        return "Each food's Nutri-Score (Open Food Facts', or worked out from its numbers), weighted by its calories\(score.parts != nil ? ". A quarter of the quality: a grade rates a food per 100 g, not how much of it you had" : "")."
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

/// One of the day's quality points: what it is against its guideline, and a bar (`fill` 0–1, a `mark` at the limit).
struct QualityLine: Hashable {
    let name: String
    let value: String
    var fill: Double = 0
    var mark: Double? = nil
    var score: Int? = nil

    static func nutrients(_ s: DayScore) -> [QualityLine] {
        let n = s.nutrients
        return [
            grams("Fibre", n?.fibre, top: 30),
            grams("Fruit & veg", n?.fruitVeg, top: 400),
            percent("Saturated fat", n?.satFat, top: 20),
            percent("Free sugars", n?.sugars, top: 25),
            grams("Salt", n?.salt, top: 10),
        ]
    }

    static func processing(_ s: DayScore) -> QualityLine {
        guard let p = s.processing else { return QualityLine(name: "Ultra-processed", value: "Not enough data") }
        return QualityLine(name: "Ultra-processed", value: "\(p.upfPct)% of kcal · under 10%",
                           fill: min(Double(p.upfPct) / 50, 1), mark: 0.2, score: p.score)
    }

    /// "22 / 30 g" for what's needed at least, "4.1 / 5 g" for a limit (with its mark), up to `top` on the bar.
    private static func grams(_ name: String, _ n: DayScore.Nutrient?, top: Double) -> QualityLine {
        guard let n, let g = n.g else { return QualityLine(name: name, value: "Not enough data") }
        let of = n.target ?? n.limit ?? top
        return QualityLine(name: name, value: "\(number(g)) / \(number(of)) g",
                           fill: min(g / (n.target ?? top), 1), mark: n.limit.map { $0 / top }, score: n.score)
    }

    private static func percent(_ name: String, _ n: DayScore.Nutrient?, top: Double) -> QualityLine {
        guard let n, let pct = n.pct else { return QualityLine(name: name, value: "Not enough data") }
        let limit = n.limit ?? 10
        return QualityLine(name: name, value: "\(number(pct))% of kcal · under \(number(limit))%",
                           fill: min(pct / top, 1), mark: limit / top, score: n.score)
    }

    static func number(_ x: Double) -> String {
        x.rounded() == x || x >= 100 ? String(Int(x.rounded())) : String(format: "%.1f", x)
    }
}

extension DayScore {
    /// The day's weakest quality point, when it's under 70: "Low on fibre: 14 / 30 g".
    var hint: String? {
        var worst: (Int, String)?
        func consider(_ score: Int?, _ text: @autoclosure () -> String) {
            if let score, score < 70, score < worst?.0 ?? 101 { worst = (score, text()) }
        }
        let n = nutrients
        let num = QualityLine.number
        consider(n?.fibre?.score, "Low on fibre: \(num(n?.fibre?.g ?? 0)) / 30 g")
        consider(n?.fruitVeg?.score, "Low on fruit & veg: \(num(n?.fruitVeg?.g ?? 0)) / 400 g")
        consider(n?.satFat?.score, "Saturated fat at \(num(n?.satFat?.pct ?? 0))% of kcal")
        consider(n?.sugars?.score, "Free sugars at \(num(n?.sugars?.pct ?? 0))% of kcal")
        consider(n?.salt?.score, "Salt at \(num(n?.salt?.g ?? 0)) g")
        consider(processing?.score, "\(processing?.upfPct ?? 0)% of kcal ultra-processed")
        return worst?.1
    }
}

/// A quality line: the name and value, and a bar coloured by its score.
struct QualityLineRow: View {
    let line: QualityLine
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(line.value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if let score = line.score {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(Grade.scoreColor(score, tint: tint))
                            .frame(width: max(6, geo.size.width * line.fill))
                        if let mark = line.mark {
                            Rectangle().fill(.secondary).frame(width: 2, height: 10)
                                .offset(x: geo.size.width * mark - 1)
                        }
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

/// Settings → Nutrition targets: the day's targets in big numbers, Coach working them out (it may ask a question or
/// two first), and below, folded away, editing them by hand and the profile (from Apple Health).
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
    @State private var answers: [String] = []
    @State private var error: String?
    @State private var saving = false
    @State private var byHand = false
    @State private var aboutYou = false

    var body: some View {
        Form {
            if loaded == nil, error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                Section {
                    TargetsSummary(base: currentBase, workouts: workouts, tint: Theme.accent)
                }
                coachSection
                Section {
                    DisclosureGroup("Edit by hand", isExpanded: $byHand) {
                        NumberField(label: "Calories", unit: "kcal", text: $calories, placeholder: "None")
                        NumberField(label: "Protein", unit: "g", text: $protein, placeholder: "None")
                        NumberField(label: "Carbs", unit: "g", text: $carbs, placeholder: "None")
                        NumberField(label: "Fat", unit: "g", text: $fat, placeholder: "None")
                        Toggle("Add what workouts burn", isOn: $workouts.on)
                    }
                } footer: {
                    if byHand { Text("For a rest day; leave one empty for no target. Save when you're done.") }
                }
                Section {
                    DisclosureGroup(isExpanded: $aboutYou) {
                        DecimalField(label: "Weight", unit: "kg", text: $weight)
                        NumberField(label: "Height", unit: "cm", text: $height, placeholder: "–")
                        NumberField(label: "Age", unit: "", text: $age, placeholder: "–")
                        Picker("Sex", selection: $sex) {
                            Text("–").tag("")
                            Text("Male").tag("male")
                            Text("Female").tag("female")
                        }
                    } label: {
                        LabeledContent("About you") {
                            Text(profileLine).lineLimit(1)
                        }
                    }
                } footer: {
                    Text("From Apple Health, with your resting and active energy, workouts and what you've eaten: what Coach works from.")
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
            if byHand || aboutYou {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(loaded == nil || saving)
                }
            }
        }
        .task { await load() }
    }

    /// The goal, Ask Coach, and its proposal with its questions.
    @ViewBuilder private var coachSection: some View {
        Section {
            Picker("Goal", selection: $goal) {
                Text("Lose").tag("lose")
                Text("Keep").tag("keep")
                Text("Gain").tag("gain")
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if let proposal {
                ProposalView(proposal: proposal)
                ForEach(proposal.asks.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(proposal.asks[i]).font(.subheadline.weight(.semibold))
                        TextField("Your answer", text: answerBinding(i), axis: .vertical)
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    Task { await use(proposal) }
                } label: {
                    Text("Use these").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || proposing)
            }
            if proposal == nil {
                Button {
                    Task { await propose() }
                } label: {
                    HStack(spacing: 8) {
                        if proposing { ProgressView() } else { Image(systemName: "wand.and.stars") }
                        Text(proposing ? "Coach is working it out…" : "Ask Coach")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(proposing)
            } else {
                Button {
                    Task { await propose() }
                } label: {
                    HStack {
                        Label(askTitle, systemImage: "arrow.clockwise")
                        if proposing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(proposing)
            }
        } header: {
            Text("Ask Coach")
        } footer: {
            if proposal == nil {
                Text("Pick your goal and Coach works out your targets from your data. Nothing changes until you tap Use these.")
            }
        }
    }

    private var askTitle: String {
        guard let proposal else { return "Ask Coach" }
        return answers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } && !proposal.asks.isEmpty
            ? "Answer and ask again" : "Ask again"
    }

    private func answerBinding(_ i: Int) -> Binding<String> {
        Binding(get: { answers.indices.contains(i) ? answers[i] : "" },
                set: { value in
                    while answers.count <= i { answers.append("") }
                    answers[i] = value
                })
    }

    /// "65.4 kg · 183 cm · 22 · male"
    private var profileLine: String {
        let parts = [weight.isEmpty ? nil : "\(weight) kg", height.isEmpty ? nil : "\(height) cm",
                     age.isEmpty ? nil : age, sex.isEmpty ? nil : sex.capitalized]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? "Not set" : line
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
            show(t.base)
            workouts = t.workouts
            var p = t.profile
            let h = await health.profile() // Apple Health's latest wins: weight changes
            p.weightKg = h.weightKg ?? p.weightKg
            p.heightCm = h.heightCm ?? p.heightCm
            p.age = h.age ?? p.age
            p.sex = h.sex ?? p.sex
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

    private func show(_ base: FoodGoals) {
        calories = base.calories.map(String.init) ?? ""
        protein = base.proteinG.map(String.init) ?? ""
        carbs = base.carbsG.map(String.init) ?? ""
        fat = base.fatG.map(String.init) ?? ""
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

    /// Saves the profile first, so Coach proposes from what's on screen; sends the answers to its last questions.
    private func propose() async {
        proposing = true
        error = nil
        defer { proposing = false }
        do {
            var current = targets
            if let loaded { current.base = loaded.base; current.workouts = loaded.workouts } // only the profile
            loaded = try await env.api.saveFoodTargets(current)
            let asked = proposal?.asks ?? []
            let given = asked.indices.compactMap { i -> TargetsAnswers.Answer? in
                let a = answers.indices.contains(i) ? answers[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return a.isEmpty ? nil : TargetsAnswers.Answer(question: asked[i], answer: a)
            }
            let got = try await env.api.proposeFoodTargets(answers: given)
            withAnimation {
                proposal = got
                answers = []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Takes Coach's numbers and saves them.
    private func use(_ p: TargetsProposal) async {
        show(p.base)
        workouts = WorkoutTargets(on: true, share: p.workouts.share, carbsPct: p.workouts.carbsPct)
        await save()
        if error == nil { withAnimation { proposal = nil } }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            loaded = try await env.api.saveFoodTargets(targets)
            error = nil
            withAnimation { byHand = false; aboutYou = false }
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

/// The day's targets in big numbers: calories, then protein, carbs and fat; what a workout day adds under them.
struct TargetsSummary: View {
    let base: FoodGoals
    let workouts: WorkoutTargets
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let kcal = base.calories {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(kcal.formatted()).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("kcal a day").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No targets yet").font(.title3.weight(.semibold))
                Text("Ask Coach to work them out from your Apple Health, or set them by hand.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if base.proteinG != nil || base.carbsG != nil || base.fatG != nil {
                HStack(spacing: 10) {
                    macro("Protein", base.proteinG)
                    macro("Carbs", base.carbsG)
                    macro("Fat", base.fatG)
                }
            }
            if base.calories != nil {
                Label(Self.workoutLine(workouts), systemImage: "figure.run")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func macro(_ name: String, _ grams: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(grams.map { "\($0) g" } ?? "–").font(.headline).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// "Workout days add what the Watch says you burned, mostly as carbs."
    static func workoutLine(_ w: WorkoutTargets) -> String {
        guard w.on, w.share > 0 else { return "Workout days are the same as rest days." }
        let pct = Int((w.share * 100).rounded())
        let how = w.carbsPct >= 60 ? "mostly as carbs" : "as carbs and fat"
        return pct == 100 ? "Workout days add what the Watch says you burned, \(how)."
                          : "Workout days add \(pct)% of what the Watch says you burned, \(how)."
    }
}

/// Coach's proposal: the numbers, what a workout adds, and why.
private struct ProposalView: View {
    let proposal: TargetsProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coach suggests").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TargetsSummary(base: proposal.base, workouts: proposal.workouts, tint: Theme.accent)
            if !proposal.why.isEmpty {
                Text(proposal.why).font(.footnote).foregroundStyle(.secondary)
            }
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
