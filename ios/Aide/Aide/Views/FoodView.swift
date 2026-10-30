import SwiftUI

/// The Food tab, for a day (today, or an earlier one from the arrows): the day's score and targets, what's left,
/// and what you ate. Meals come from photos with a few words, or the words alone, that Coach names and estimates (a
/// packet's barcode in a photo brings its real numbers); tap one to fix the numbers, swipe to delete. Every meal also
/// goes to Apple Health (`HealthService.writeMeals`). The Control Center buttons and `aide://meal/…` open it.
struct FoodView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var health: HealthService

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var food: FoodDay?
    /// An older server without food.
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

    var body: some View {
        NavigationStack {
            List {
                Section { DayHeader(day: $day) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                if noFood {
                    Section {
                        Text("This server doesn't keep a food log yet.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Theme.row)
                } else {
                    if let food {
                        Section {
                            NavigationLink { NutritionDayView(day: food, tint: coach.tint) } label: {
                                DayScoreCard(day: food, isToday: isToday, tint: coach.tint)
                            }
                        }
                        .listRowBackground(Theme.row)
                    }
                    foodSection
                    // Its own section: a clear row inside the card's section cut off the card's rounded bottom.
                    Section { logButton }
                    mealsSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Food")
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
            .refreshable { await loadFood() }
            .onChange(of: env.mealLog) { startMealLog() }
            .task {
                startMealLog() // a Control Center button that launched the app
                #if DEBUG
                if settings.isPreview, let code = UserDefaults.standard.string(forKey: "previewBarcode") {
                    scanned = ScannedCode(code: code)
                }
                #endif
            }
            .task(id: day) { await loadFood() }
        }
    }

    /// From Control Center: today's food with the camera up (the library without one), or the describe box.
    private func startMealLog() {
        guard let way = env.mealLog else { return }
        env.mealLog = nil
        day = Calendar.current.startOfDay(for: Date())
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
