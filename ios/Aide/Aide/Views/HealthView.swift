import SwiftUI

/// The Health tab: what you ate, day by day, and your habits. Meals come from a photo (or a few words) that Coach
/// names and estimates; tap one to fix the numbers, swipe to delete. Habits tick off, edit and delete as before.
struct HealthView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var food: FoodDay?
    @State private var foodDays: [FoodDaySummary] = []
    /// An older server without food: the food part is left out.
    @State private var noFood = false
    @State private var foodError: String?
    @State private var logging = false
    @State private var logReply: String?
    /// Coach's Food log chat, once a log has told us which it is.
    @State private var logChat: String?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var describing = false
    @State private var mealText = ""
    @State private var showGoals = false
    @State private var editingMeal: Meal?

    @State private var habits: [Habit] = []
    @State private var habitsLoaded = false
    @State private var habitsError: String?
    @State private var addingHabit = false
    @State private var editingHabit: Habit?

    private var coach: Agent { chat.agent("coach") }

    /// The last seven days, today last.
    private var week: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            List {
                if !noFood {
                    Section {
                        WeekStrip(days: week, summaries: Dictionary(foodDays.map { ($0.date, $0) }) { _, last in last },
                                  goal: food?.goals.calories, tint: coach.tint, selection: $day)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    foodSection
                    // Its own section: a clear row inside the card's section cut off the card's rounded bottom.
                    Section { logButton }
                    mealsSection
                }
                habitsSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Health")
            .sheet(isPresented: $showGoals) {
                FoodGoalsSheet(goals: food?.goals ?? FoodGoals()) { await saveGoals($0) }
            }
            .sheet(item: $editingMeal) { meal in
                MealSheet(meal: meal, save: { await update(meal, $0) }, delete: { await remove(meal) })
            }
            .sheet(isPresented: $addingHabit) { HabitSheet(habit: nil) { await addHabit($0) } }
            .sheet(item: $editingHabit) { habit in HabitSheet(habit: habit) { await updateHabit(habit, $0) } }
            .alert("What did you eat?", isPresented: $describing) {
                TextField("A cappuccino and a croissant", text: $mealText)
                Button("Cancel", role: .cancel) { mealText = "" }
                Button("Log") {
                    let text = mealText.trimmingCharacters(in: .whitespacesAndNewlines)
                    mealText = ""
                    if !text.isEmpty { Task { await log(text: text) } }
                }
            }
            .photoSources(camera: $showCamera, library: $showLibrary, limit: 4) { photos in
                Task { await log(photos: photos) }
            }
            .refreshable {
                async let food: Void = loadFood()
                await loadHabits()
                await food
            }
            .task { await loadHabits() }
            .task(id: day) { await loadFood() }
        }
    }

    // MARK: Food

    private var foodSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                FoodSummary(totals: food?.totals ?? FoodTotals(), goals: food?.goals ?? FoodGoals(), tint: coach.tint)
                if logging {
                    HStack(spacing: 10) {
                        LivePebble(mood: "thinking", size: 26, figure: coach.figure)
                            .foregroundStyle(coach.tint)
                            .allowsHitTesting(false)
                        Text("\(coach.name) is looking at it…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if let logReply, !logReply.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        AgentMark(agent: coach, size: 26)
                        Text(logReply.markdown).font(.callout)
                    }
                    .transition(.opacity)
                }
                if let foodError {
                    Label(foodError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
            }
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.25), value: logging)
            if let id = foodChat {
                Button {
                    push.route = .conversation(id) // the same way a tapped notification opens a chat
                } label: {
                    Label("Open Food log chat", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        } header: {
            HStack {
                Text(dayTitle)
                Spacer()
                Button("Goals") { showGoals = true }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .disabled(!settings.isConfigured)
            }
        }
        .listRowBackground(Theme.row)
    }

    /// Camera, library or a few words; Coach does the rest.
    private var logButton: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose photos", systemImage: "photo.on.rectangle") { showLibrary = true }
            Button("Describe it", systemImage: "text.cursor") { describing = true }
        } label: {
            Label(isToday ? "Log a meal" : "Log a meal on \(day.formatted(.dateTime.weekday(.wide)))",
                  systemImage: "camera.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: Capsule())
        }
        .disabled(!settings.isConfigured || logging)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    private var mealsSection: some View {
        Section("Meals") {
            let meals = food?.meals ?? []
            if meals.isEmpty {
                Text(isToday ? "Nothing logged yet today. Take a photo of what you eat, or tell Coach in chat."
                     : "Nothing logged that day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(meals) { meal in
                Button { editingMeal = meal } label: { MealRow(meal: meal) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit")
            }
            .onDelete { offsets in
                let doomed = offsets.map { meals[$0] }
                Task { for meal in doomed { if let message = await remove(meal) { foodError = message } } }
            }
        }
        .listRowBackground(Theme.row)
    }

    /// "Today", "Yesterday" or "Monday 19 October".
    private var dayTitle: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The chat the last log went to, else the one called "Food log" in the chat list.
    private var foodChat: String? {
        logChat ?? chat.conversations.first { $0.title == "Food log" }?.id
    }

    private func loadFood() async {
        guard settings.isConfigured else { return }
        let shown = day
        do {
            async let dayFood = env.api.food(date: shown)
            async let days = env.api.foodDays(from: week[0], to: week[week.count - 1])
            let (loaded, summaries) = try await (dayFood, days)
            guard shown == day else { return } // another day was picked meanwhile
            food = loaded
            foodDays = summaries
            foodError = nil
            noFood = false
        } catch APIError.server(let status, _) where status == 404 {
            noFood = true
        } catch {
            if !Task.isCancelled { foodError = error.localizedDescription } // not when another day was picked
        }
    }

    /// Uploads the photos, then Coach logs the meal on the chosen day and says what it made of it.
    private func log(photos: [PickedPhoto] = [], text: String? = nil) async {
        logging = true
        logReply = nil
        foodError = nil
        defer { logging = false }
        do {
            var ids: [String] = []
            for photo in photos { ids.append(try await env.api.uploadPhoto(photo.jpeg)) }
            let reply = try await env.api.logFood(FoodLogRequest(photos: ids, text: text,
                                                                 date: isToday ? nil : Wire.dayString(day)))
            withAnimation { logReply = reply.reply }
            if let id = reply.conversationId { logChat = id }
            await loadFood()
            await chat.loadConversations()
        } catch {
            foodError = error.localizedDescription
        }
    }

    private func update(_ meal: Meal, _ changes: MealChanges) async -> String? {
        do {
            _ = try await env.api.updateMeal(meal.id, changes)
            await loadFood() // the time may have moved it to another day
            return nil
        } catch { return error.localizedDescription }
    }

    private func remove(_ meal: Meal) async -> String? {
        do {
            try await env.api.deleteMeal(meal.id)
            food?.meals.removeAll { $0.id == meal.id }
            await loadFood()
            return nil
        } catch { return error.localizedDescription }
    }

    private func saveGoals(_ goals: FoodGoals) async -> String? {
        do {
            food?.goals = try await env.api.saveFoodGoals(goals)
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: Habits

    private var habitsSection: some View {
        Section {
            if let habitsError {
                Label(habitsError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if habits.isEmpty && habitsLoaded && habitsError == nil {
                Text("No habits yet. Tap + to add one, or tell Aide in chat: \"add a gym habit, three times a week\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(habits) { habit in
                HabitRow(habit: habit, toggle: { Task { await toggle(habit) } }, edit: { editingHabit = habit })
            }
            .onDelete { offsets in
                let doomed = offsets.map { habits[$0] }
                Task { for h in doomed { await removeHabit(h) } }
            }
        } header: {
            HStack {
                Text("Habits")
                Spacer()
                Button { addingHabit = true } label: { Image(systemName: "plus") }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Add habit")
                    .disabled(!settings.isConfigured)
            }
        }
        .listRowBackground(Theme.row)
    }

    private func loadHabits() async {
        guard settings.isConfigured else { return }
        do { habits = try await env.api.habits(); habitsError = nil } catch { habitsError = error.localizedDescription }
        habitsLoaded = true
    }

    private func toggle(_ habit: Habit) async {
        do {
            let updated = try await env.api.checkHabit(habit.id, done: !habit.doneToday)
            if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = updated }
        } catch { habitsError = error.localizedDescription }
    }

    private func removeHabit(_ habit: Habit) async {
        do {
            try await env.api.deleteHabit(habit.id)
            habits.removeAll { $0.id == habit.id }
        } catch { habitsError = error.localizedDescription }
    }

    private func updateHabit(_ habit: Habit, _ changes: HabitNew) async -> String? {
        do {
            let updated = try await env.api.updateHabit(habit.id, changes)
            if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = updated }
            return nil
        } catch APIError.server(let status, _) where status == 404 || status == 405 {
            return "The server can't edit habits yet."
        } catch { return error.localizedDescription }
    }

    private func addHabit(_ habit: HabitNew) async -> String? {
        do {
            habits.append(try await env.api.addHabit(habit))
            return nil
        } catch { return error.localizedDescription }
    }
}
