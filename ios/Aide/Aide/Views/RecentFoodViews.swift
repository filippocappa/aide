import SwiftUI

/// "Recent" on Health → Food: what you eat, to have it again without Coach or a model call (docs/API.md, "Food",
/// `GET /v1/food/recent`). Meals of several items you've had, then foods, both by how often you have them (at this time
/// of day counting double), with a search over every saved food. A meal is logged again as it was; a food opens its
/// how-much page (the scan sheet); the + on foods builds one meal of several at their usual portions. Latest lists every
/// food as it was had, newest first, by day (`order=latest`).
struct RecentFoodsSheet: View {
    enum Order: String { case usual, latest }

    /// The day being looked at; nil is today.
    let date: String?
    var tint: Color = Theme.accent
    /// After logging: the meal, to say so and reload.
    let logged: (Meal) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Usual or Latest, the last one kept.
    @AppStorage("recentFoodsOrder") private var order: Order = .usual
    @State private var recent: RecentFoods?
    @State private var error: String?
    /// The foods picked for one meal, in the order picked, with the grams typed for each.
    @State private var picked: [SavedFood] = []
    @State private var grams: [Int: String] = [:]
    @State private var single: SavedFood?
    @State private var again: RecentMeal?
    @State private var saving = false
    /// The how-much page logged its food: close this sheet too once it has gone.
    @State private var closeAfter = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Order", selection: $order) {
                    Text("Usual").tag(Order.usual)
                    Text("Latest").tag(Order.latest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                if let recent {
                    if recent.foods.isEmpty && recent.meals.isEmpty {
                        Text(query.isEmpty
                             ? "Nothing here yet. Foods show up once you've logged them, from a photo, a description or a barcode."
                             : order == .latest ? "You haven't had a food called that in the last 90 days."
                             : "No saved food called that. Describe it to Coach instead.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if order == .latest {
                        ForEach(days(recent.foods), id: \.day) { group in
                            Section(dayTitle(group.day)) {
                                ForEach(group.foods) { item in latestRow(item) }
                            }
                        }
                    } else {
                        usual(recent)
                    }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your foods")
            #else
            .searchable(text: $query, prompt: "Search your foods")
            #endif
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { if !picked.isEmpty { together } }
            .animation(.snappy, value: picked)
            .navigationTitle("Recent")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle("Recent")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #endif
            }
            .task(id: "\(order.rawValue)|\(query)") {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) } // while typing
                guard !Task.isCancelled else { return }
                await load()
            }
            .onChange(of: order) { recent = nil }
            .confirmationDialog(again.map { "\($0.name), \($0.calories) kcal" } ?? "", isPresented: Binding(
                get: { again != nil }, set: { if !$0 { again = nil } }
            ), titleVisibility: .visible, presenting: again) { meal in
                Button(date == nil ? "Log it again now" : "Log it again that day") { Task { await logAgain(meal) } }
                Button("Cancel", role: .cancel) {}
            } message: { meal in
                Text(meal.items.map { item in item.grams.map { "\(item.name) \(ScanSheet.g($0))" } ?? item.name }
                    .joined(separator: ", "))
            }
            .sheet(item: $single, onDismiss: { if closeAfter { dismiss() } }) { food in
                ScanSheet(barcode: food.barcode ?? "", date: date, tint: tint, logged: { meal in
                    closeAfter = true
                    logged(meal)
                }, preset: food)
            }
        }
        .presentationDetents([.large])
    }

    /// Usual: meals of several items, then foods, by how often you have them.
    @ViewBuilder private func usual(_ recent: RecentFoods) -> some View {
                    if !recent.meals.isEmpty {
                        Section(query.isEmpty ? "Meals you have" : "Meals") {
                            ForEach(recent.meals) { meal in
                                Button { again = meal } label: { mealRow(meal) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !recent.foods.isEmpty {
                        Section {
                            ForEach(recent.foods) { item in foodRow(item) }
                        } header: {
                            Text("Foods")
                        } footer: {
                            Text("Tap a food to say how much. + adds it to one meal with others, at your usual portion.")
                        }
                    }
    }

    // MARK: Rows

    private func mealRow(_ meal: RecentMeal) -> some View {
        HStack(spacing: 12) {
            MealEmoji(emoji: meal.emoji, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(meal.items.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(meal.calories) kcal").font(.subheadline).monospacedDigit()
                if meal.times > 1 {
                    Text("×\(meal.times)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func foodRow(_ item: RecentFood) -> some View {
        let food = item.food
        let on = picked.contains { $0.id == food.id }
        return HStack(spacing: 12) {
            Button { single = food } label: {
                HStack(spacing: 12) {
                    MealEmoji(emoji: item.emoji, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(food.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(subtitle(food)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if on {
                HStack(spacing: 2) {
                    TextField("0", text: Binding(get: { grams[food.id] ?? "" }, set: { grams[food.id] = $0 }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 52)
                        .accessibilityLabel("Grams of \(food.name)")
                    Text("g").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.chip, in: Capsule())
            }
            if on || food.defaultGrams != nil {
                Button { toggle(food) } label: {
                    Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title2)
                        .foregroundStyle(on ? tint : Theme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(on ? "Take \(food.name) out of the meal" : "Add \(food.name) to one meal")
            }
        }
    }

    /// "Fage · usually 170 g, 90 kcal".
    private func subtitle(_ food: SavedFood) -> String {
        var parts: [String] = []
        if !food.brand.isEmpty { parts.append(food.brand) }
        if let g = food.usualG {
            parts.append("usually \(ScanSheet.g(g)), \(food.portion(g).calories) kcal")
        } else if let g = food.servingG {
            parts.append("a serving is \(ScanSheet.g(g))")
        } else {
            parts.append("\(Int(food.kcal100g.rounded())) kcal per 100 g")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Latest

    /// The foods by the day they were had, newest first (the server's order kept inside a day).
    private func days(_ foods: [RecentFood]) -> [(day: Date, foods: [RecentFood])] {
        var out: [(day: Date, foods: [RecentFood])] = []
        for item in foods {
            let day = Calendar.current.startOfDay(for: item.eatenAt.flatMap(Wire.parse) ?? .distantPast)
            if out.last?.day == day { out[out.count - 1].foods.append(item) } else { out.append((day, [item])) }
        }
        return out
    }

    /// "Today", "Yesterday" or "Saturday 1 November".
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// One time a food was had: its name, then "Voiello · 300 g · 12:04" and the meal it was in. Tap: how much, to
    /// have it again.
    private func latestRow(_ item: RecentFood) -> some View {
        let food = item.food
        let time = item.eatenAt.flatMap(Wire.parse)?.formatted(date: .omitted, time: .shortened)
        let line = [food.brand.isEmpty ? nil : food.brand, item.grams.map(ScanSheet.g), time].compactMap { $0 }
        return Button { single = food } label: {
            HStack(spacing: 12) {
                MealEmoji(emoji: item.emoji, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(line.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let meal = item.meal, meal != food.name, !meal.hasPrefix(food.name) {
                        Text("in \(meal)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let g = item.grams {
                    Text("\(food.portion(g).calories) kcal").font(.subheadline).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: One meal of several

    /// The bar under the list while foods are picked: what they come to, and Log.
    private var together: some View {
        let kcal = picked.reduce(0) { sum, food in sum + (amount(food).map { food.portion($0).calories } ?? 0) }
        let ready = picked.allSatisfy { amount($0) != nil }
        return VStack(spacing: 6) {
            Button { Task { await logTogether() } } label: {
                Text(saving ? "Logging…" : picked.count == 1 ? "Log it · \(kcal) kcal" : "Log \(picked.count) together · \(kcal) kcal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent.opacity(ready && !saving ? 1 : 0.4), in: Capsule())
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .disabled(!ready || saving)
            Text(picked.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.grouped.opacity(0.94).ignoresSafeArea())
    }

    private func toggle(_ food: SavedFood) {
        if let i = picked.firstIndex(where: { $0.id == food.id }) {
            picked.remove(at: i)
            grams[food.id] = nil
        } else {
            picked.append(food)
            grams[food.id] = food.defaultGrams.map(ScanSheet.number) ?? ""
        }
    }

    /// The grams typed for a picked food (a sum works, as on the scan page); nil when empty or not a number.
    private func amount(_ food: SavedFood) -> Double? {
        Arithmetic.evaluate(grams[food.id] ?? "").flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: Work

    private func load() async {
        do {
            let loaded = try await env.api.recentFoods(query: query, latest: order == .latest)
            guard !Task.isCancelled else { return }
            recent = loaded
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func logTogether() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let meal = try await env.api.logFoods(FoodsLogRequest(
                items: picked.map { FoodsLogRequest.Item(foodId: $0.id, grams: amount($0)) }, date: date))
            logged(meal)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func logAgain(_ meal: RecentMeal) async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            logged(try await env.api.mealAgain(meal.id, FoodPortion(date: date)))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
