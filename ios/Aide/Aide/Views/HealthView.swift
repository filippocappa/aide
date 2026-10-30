import SwiftUI

/// The Health tab, one page for a day (today, or an earlier one from the arrows): Strain, Recovery and Sleep as rings
/// (docs/API.md, "Scores"; each opens its page) with the day in a sentence, last night's numbers against your usual
/// range, the day's heart rate and workouts, activity and weight, then Food: what you ate; meals come from photos with
/// a few words, or the words alone, that Coach names and estimates (a packet's barcode in a photo brings its real
/// numbers); tap one to fix the numbers, swipe to delete. Every meal also goes to Apple Health
/// (`HealthService.writeMeals`). (Habits are on Today.)
struct HealthView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var health: HealthService

    /// The day's scores; nil while loading or from a server without them.
    @State private var scores: HealthScores?
    @State private var scoresLoaded = false
    @State private var scoreKind: ScoreKind?
    /// Newest first; nil while loading.
    @State private var bodyDays: [HealthDayReading]?
    @State private var bodyError: String?
    @State private var metric: HealthMetric?
    @State private var weight: WeightList?
    @State private var showWeight = false
    @State private var loggingWeight = false

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var food: FoodDay?
    /// An older server without food: the food part is left out.
    @State private var noFood = false
    @State private var foodError: String?
    @State private var logging = false
    @State private var logReply: String?
    /// Coach's Food log chat, once a log has told us which it is.
    @State private var logChat: String?
    @State private var showCamera = false
    @State private var cameraResult: MealCameraResult?
    @State private var showLibrary = false
    @State private var describing = false
    @State private var mealText = ""
    /// Photos just picked or taken, waiting for their description.
    @State private var pickedPhotos: PickedMeal?
    @State private var scanned: ScannedCode?
    /// "Ask Coach instead" on a barcode's sheet: the photo, sent the usual way once the sheet is gone.
    @State private var coachInstead: PickedPhoto?
    @State private var typingBarcode = false
    @State private var barcodeText = ""
    @State private var showGoals = false
    @State private var editingMeal: Meal?

    private var coach: Agent { chat.agent("coach") }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// The chosen day's reading from Apple Health.
    private var reading: HealthDayReading? { bodyDays?.first { $0.date == Wire.dayString(day) } }

    /// The days up to the chosen one, newest first: the tiles show the chosen day's numbers.
    private var daysUpTo: [HealthDayReading] {
        let shown = Wire.dayString(day)
        return (bodyDays ?? []).filter { $0.date <= shown }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section { dayHeader }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    scoreSections
                    weightSection
                    if !noFood {
                        if let food {
                            Section {
                                NavigationLink { NutritionDayView(day: food, tint: coach.tint) } label: {
                                    DayScoreCard(day: food, isToday: isToday, tint: coach.tint)
                                }
                            } header: {
                                sectionHeader("Food", icon: "fork.knife", color: coach.tint)
                            }
                            .listRowBackground(Theme.row)
                            .id("food")
                        }
                        foodSection
                        // Its own section: a clear row inside the card's section cut off the card's rounded bottom.
                        Section { logButton }
                        mealsSection
                    }
                }
                .onChange(of: scrollToFood) {
                    if scrollToFood { withAnimation { proxy.scrollTo("food", anchor: .top) }; scrollToFood = false }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Health")
            .navigationDestination(item: $metric) { m in HealthMetricView(metric: m, days: bodyDays ?? []) }
            .navigationDestination(item: $scoreKind) { kind in
                if let scores { ScoreDetailView(kind: kind, scores: scores, day: reading, date: day) }
            }
            .navigationDestination(isPresented: $showWeight) { WeightView { await loadWeight() } }
            .weightEntry(isPresented: $loggingWeight) { await loadWeight() }
            .sheet(isPresented: $showGoals, onDismiss: { Task { await loadFood() } }) {
                NavigationStack { NutritionTargetsView(inSheet: true) }
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
            .fullScreenCover(isPresented: $showCamera, onDismiss: afterCamera) {
                MealCameraView(tint: coach.tint, date: isToday ? nil : Wire.dayString(day)) { cameraResult = $0 }
            }
            // The meal camera above takes photos here; the library comes from this.
            .photoSources(camera: .constant(false), library: $showLibrary, limit: 4, barcodes: true) { photos in
                // A lone packet with its barcode: the real numbers and how much, no model call. Anything more
                // (other photos) goes to Coach, with the barcodes.
                if photos.count == 1, let code = photos[0].barcodes.first {
                    scanned = ScannedCode(code: code, photo: photos[0])
                } else {
                    pickedPhotos = PickedMeal(photos: photos)
                }
            }
            .sheet(item: $pickedPhotos) { picked in
                MealPhotosSheet(photos: picked.photos) { text in Task { await log(photos: picked.photos, text: text) } }
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
            .sheet(item: $scanned, onDismiss: {
                if let photo = coachInstead { pickedPhotos = PickedMeal(photos: [photo]) }
                coachInstead = nil
            }) { code in
                ScanSheet(barcode: code.code, date: isToday ? nil : Wire.dayString(day), tint: coach.tint,
                          logged: loggedPacket, askCoach: code.photo.map { photo in { coachInstead = photo } })
            }
            .refreshable {
                await loadBody(upload: true)
                async let food: Void = loadFood()
                async let scores: Void = loadScores()
                await food
                await scores
            }
            .onChange(of: env.mealLog) { startMealLog() }
            .task {
                startMealLog() // a Control Center button that launched the app
                await loadBody()
                #if DEBUG
                if settings.isPreview, let m = UserDefaults.standard.string(forKey: "previewMetric") {
                    metric = HealthMetric(rawValue: m)
                }
                if settings.isPreview, case let back = UserDefaults.standard.integer(forKey: "previewDaysBack"), back > 0,
                   let earlier = Calendar.current.date(byAdding: .day, value: -back, to: day) {
                    day = earlier
                }
                if settings.isPreview, let k = UserDefaults.standard.string(forKey: "previewScore") {
                    scoreKind = ScoreKind(rawValue: k)
                }
                if settings.isPreview, let code = UserDefaults.standard.string(forKey: "previewBarcode") {
                    scanned = ScannedCode(code: code)
                }
                #endif
            }
            .task(id: day) {
                async let food: Void = loadFood()
                async let scores: Void = loadScores()
                await food
                await scores
            }
        }
    }

    // MARK: The day

    @State private var scrollToFood = false

    /// "‹ Today, 30 October ›": everything below follows it.
    private var dayHeader: some View {
        HStack {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Day before")
            Spacer()
            VStack(spacing: 0) {
                Text(dayTitle).font(.headline)
                if isToday || Calendar.current.isDateInYesterday(day) {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .disabled(isToday)
            .accessibilityLabel("Day after")
        }
        .buttonStyle(.borderless)
        .tint(.primary)
    }

    private func move(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= Date() else { return }
        withAnimation(.snappy) { day = Calendar.current.startOfDay(for: next) }
    }

    @ViewBuilder private var scoreSections: some View {
        if scoresLoaded || scores != nil {
            Section {
                ScoresCard(scores: scores, coach: coach, open: { kind in if scores != nil { scoreKind = kind } },
                           ask: { push.route = .agent(coach.id) })
            }
            .listRowBackground(Theme.row)
        } else if bodyError == nil {
            SkeletonSections(sections: 1, rows: 2, mark: false)
        }
        if let bodyError {
            Section { Label(bodyError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
        } else if bodyDays?.isEmpty == true {
            Section {
                Text("Nothing from Apple Health yet. Turn it on in Settings → Apple Health, and wear your Watch to bed for sleep and recovery.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        let vitals = vitalRows
        if !vitals.isEmpty {
            Section {
                ForEach(vitals, id: \.0) { m, v in
                    Button { metric = m } label: { VitalRow(metric: m, vital: v).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the chart")
                }
            } header: {
                sectionHeader("Last night", icon: "moon.zzz.fill", color: .indigo)
            } footer: {
                Text("The middle of each gauge is your usual range, from the 60 days before.")
            }
            .listRowBackground(Theme.row)
        }
        if let reading, reading.hrHourly?.contains(where: { $0 != nil }) == true {
            Section {
                DayHeartChart(day: reading)
            } header: {
                sectionHeader("Heart rate", icon: "heart.fill", color: .red)
            }
            .listRowBackground(Theme.row)
        }
        if let workouts = reading?.workouts, !workouts.isEmpty {
            Section {
                ForEach(Array(workouts.enumerated()), id: \.offset) { _, w in
                    WorkoutRow(date: reading?.date ?? "", workout: w,
                               strain: scores?.strain?.workouts.first { $0.id == w.id }?.strain)
                }
            } header: {
                sectionHeader("Workouts", icon: "figure.run", color: ScoreColors.strain[1])
            }
            .listRowBackground(Theme.row)
        }
        let activity: [HealthMetric] = [.steps, .activeKcal, .exercise].filter { m in reading.flatMap(m.value) != nil }
        if !activity.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(activity) { m in
                        Button { metric = m } label: { MetricTile(metric: m, days: daysUpTo) }
                            .buttonStyle(CardPress())
                    }
                }
                .padding(.vertical, 2)
            } header: {
                sectionHeader("Activity", icon: "figure.walk", color: .orange)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// Last night's numbers that have a value, with their usual range.
    private var vitalRows: [(HealthMetric, HealthScores.Vital)] {
        guard let v = scores?.vitals else { return [] }
        let all: [(HealthMetric, HealthScores.Vital?)] = [(.hrv, v.hrvMs), (.restingHr, v.restingHr),
                                                         (.breathing, v.respiratoryRate), (.wristTemp, v.wristTempC),
                                                         (.sleep, v.asleepMin)]
        return all.compactMap { m, x in x.flatMap { $0.value != nil ? (m, $0) : nil } }
    }

    @ViewBuilder private var weightSection: some View {
        if let weight, isToday {
            Section {
                WeightCard(weight: weight, open: { showWeight = true }, log: { loggingWeight = true })
            } header: {
                sectionHeader("Weight", icon: "scalemass.fill", color: WeightSummary.color)
            }
            .listRowBackground(Theme.row)
        }
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
    }

    private func loadScores() async {
        guard settings.isConfigured else { return }
        let shown = day
        do {
            let loaded = try await env.api.healthScores(date: shown)
            guard shown == day else { return }
            withAnimation { scores = loaded }
        } catch {
            if Task.isCancelled { return }
            scores = nil // an older server without scores, or none for the day
        }
        scoresLoaded = true
    }

    // MARK: Food

    /// From Control Center: today's food with the camera up (the library without one), or the describe box.
    private func startMealLog() {
        guard let way = env.mealLog else { return }
        env.mealLog = nil
        day = Calendar.current.startOfDay(for: Date())
        scrollToFood = true
        Task {
            try? await Task.sleep(for: .milliseconds(500)) // after the tab switch and any sheet going away
            switch way {
            case .photo where MealCamera.isAvailable: showCamera = true
            case .photo: showLibrary = true
            case .describe: describing = true
            }
        }
    }

    /// What the meal camera ended with, once it has gone (a sheet can't open while it's still on screen).
    private func afterCamera() {
        guard let result = cameraResult else { return }
        cameraResult = nil
        switch result {
        case .photos(let photos): pickedPhotos = PickedMeal(photos: photos)
        case .logged(let meal): loggedPacket(meal)
        case .library: showLibrary = true
        case .describe: describing = true
        }
    }

    /// A packet logged from its barcode: say so, and the day again.
    private func loggedPacket(_ meal: Meal) {
        withAnimation { logReply = "Logged **\(meal.name)**: \(meal.calories) kcal." }
        Task {
            await loadFood()
            await health.writeMeals()
        }
    }

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
                if food == nil { sectionHeader("Food", icon: "fork.knife", color: coach.tint) }
                Spacer()
                Button("Targets") { showGoals = true }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .disabled(!settings.isConfigured)
            }
        }
        .listRowBackground(Theme.row)
    }

    /// Camera, library or a few words; Coach (or, for a photo of one packet, the server) does the rest.
    private var logButton: some View {
        Menu {
            if MealCamera.isAvailable {
                Button("Take photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose photos", systemImage: "photo.on.rectangle") { showLibrary = true }
            Button("Describe it", systemImage: "text.cursor") { describing = true }
            Section {
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
            let meals = Meal.newestFirst(food?.meals ?? [])
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
            let loaded = try await env.api.food(date: shown)
            guard shown == day else { return } // another day was picked meanwhile
            food = loaded
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
        async let weightLoad: Void = loadWeight()
        do {
            bodyDays = try await env.api.healthDays()
            bodyError = nil
        } catch APIError.server(let status, _) where status == 404 {
            bodyDays = []
        } catch {
            if !Task.isCancelled { bodyError = error.localizedDescription }
        }
        await weightLoad
    }

    private func loadWeight() async {
        weight = try? await env.api.weight(days: 30) // nil from a server without weights: no card
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
            var codes: [String] = []
            for code in photos.flatMap(\.barcodes) where !codes.contains(code) { codes.append(code) }
            let reply = try await env.api.logFood(FoodLogRequest(photos: ids, text: text,
                                                                 date: isToday ? nil : Wire.dayString(day),
                                                                 barcodes: Array(codes.prefix(4))))
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
}
