import SwiftUI

/// The Health tab, in two pages. Body: what Apple Health says (sleep, recovery, activity, workouts), each opening
/// its chart. Food: what you ate, day by day; meals come from photos with a few words, or the words alone, that
/// Coach names and estimates, or from a scanned barcode with its real numbers; tap one to fix the numbers, swipe to
/// delete. Every meal also goes to Apple Health
/// (`HealthService.writeMeals`). (Habits are on Today.)
struct HealthView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var health: HealthService

    @AppStorage("healthPage") private var page = "body"
    /// Newest first; nil while loading.
    @State private var bodyDays: [HealthDayReading]?
    @State private var bodyError: String?
    @State private var metric: HealthMetric?

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
    /// Photos just picked or taken, waiting for their description.
    @State private var pickedPhotos: PickedMeal?
    @State private var showScanner = false
    /// What the scanner read, or that the digits are to be typed, acted on once its cover is gone.
    @State private var afterScanner: ScannerOutcome?
    @State private var scanned: ScannedCode?
    @State private var typingBarcode = false
    @State private var barcodeText = ""
    @State private var showGoals = false
    @State private var editingMeal: Meal?

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
                Section {
                    Picker("Page", selection: $page) {
                        Text("Body").tag("body")
                        if !noFood { Text("Food").tag("food") }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch page {
                case "food" where !noFood:
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
                default:
                    BodySections(days: bodyDays, error: bodyError) { metric = $0 }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Health")
            .navigationDestination(item: $metric) { m in HealthMetricView(metric: m, days: bodyDays ?? []) }
            .sheet(isPresented: $showGoals) {
                FoodGoalsSheet(goals: food?.goals ?? FoodGoals()) { await saveGoals($0) }
            }
            .sheet(item: $editingMeal) { meal in
                MealSheet(meal: meal, save: { await update(meal, $0) }, delete: { await remove(meal) })
            }
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
                pickedPhotos = PickedMeal(photos: photos)
            }
            .sheet(item: $pickedPhotos) { picked in
                MealPhotosSheet(photos: picked.photos) { text in Task { await log(photos: picked.photos, text: text) } }
            }
            .fullScreenCover(isPresented: $showScanner, onDismiss: {
                switch afterScanner {
                case .code(let code): scanned = ScannedCode(code: code)
                case .type: typingBarcode = true
                case nil: break
                }
                afterScanner = nil
            }) {
                BarcodeScannerScreen(onScan: { afterScanner = .code($0) }, typeInstead: { afterScanner = .type })
            }
            .alert("Barcode", isPresented: $typingBarcode) {
                TextField("8001505005707", text: $barcodeText).keyboardType(.numberPad)
                Button("Cancel", role: .cancel) { barcodeText = "" }
                Button("Look up") {
                    let code = barcodeText.filter(\.isNumber)
                    barcodeText = ""
                    if !code.isEmpty { scanned = ScannedCode(code: code) }
                }
            } message: {
                Text("The digits under the barcode.")
            }
            .sheet(item: $scanned) { code in
                ScanSheet(barcode: code.code, date: isToday ? nil : Wire.dayString(day)) { meal in
                    withAnimation { logReply = "Logged **\(meal.name)**: \(meal.calories) kcal." }
                    Task {
                        await loadFood()
                        await health.writeMeals()
                    }
                }
            }
            .refreshable {
                async let food: Void = loadFood()
                async let body: Void = loadBody(upload: true)
                await food
                await body
            }
            .task {
                await loadBody()
                #if DEBUG
                if settings.isPreview, let m = UserDefaults.standard.string(forKey: "previewMetric") {
                    page = "body"; metric = HealthMetric(rawValue: m)
                }
                #endif
            }
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

    /// Camera, library, a few words or a barcode; Coach (or, for a barcode, the server) does the rest.
    private var logButton: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose photos", systemImage: "photo.on.rectangle") { showLibrary = true }
            Button("Describe it", systemImage: "text.cursor") { describing = true }
            if BarcodeScanner.isSupported {
                Button("Scan barcode", systemImage: "barcode.viewfinder") { showScanner = true }
            } else {
                Button("Type a barcode", systemImage: "barcode") { typingBarcode = true }
            }
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

    /// What the server has from Apple Health; a pull sends the phone's last two days first.
    private func loadBody(upload: Bool = false) async {
        guard settings.isConfigured else { return }
        if upload { _ = await health.upload(days: 2) }
        do {
            bodyDays = try await env.api.healthDays()
            bodyError = nil
        } catch APIError.server(let status, _) where status == 404 {
            bodyDays = []
        } catch {
            if !Task.isCancelled { bodyError = error.localizedDescription }
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
            await health.writeMeals()
        } catch {
            foodError = error.localizedDescription
        }
    }

    private func update(_ meal: Meal, _ changes: MealChanges) async -> String? {
        do {
            _ = try await env.api.updateMeal(meal.id, changes)
            await loadFood() // the time may have moved it to another day
            Task { await health.writeMeals() }
            return nil
        } catch { return error.localizedDescription }
    }

    private func remove(_ meal: Meal) async -> String? {
        do {
            try await env.api.deleteMeal(meal.id)
            food?.meals.removeAll { $0.id == meal.id }
            await loadFood()
            Task { await health.writeMeals() }
            return nil
        } catch { return error.localizedDescription }
    }

    private func saveGoals(_ goals: FoodGoals) async -> String? {
        do {
            food?.goals = try await env.api.saveFoodGoals(goals)
            return nil
        } catch { return error.localizedDescription }
    }
}

private enum ScannerOutcome {
    case code(String)
    case type
}
