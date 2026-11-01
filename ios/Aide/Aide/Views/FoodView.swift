import SwiftUI

/// The Mac's Food section: the food page on its own, with its own day.
struct FoodView: View {
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            FoodPage(day: $day)
                .background(Theme.grouped)
                .navigationTitle("Food")
        }
    }
}

/// Food for a day, in cards (#33): the week as rings (tap a day), the day's score and targets, what's left, the three
/// ways to log, and what you ate. On the phone it is the Food half of the Health tab, under its Body · Food switch,
/// sharing its day. Meals come from photos with a few words, or the words alone, that Coach names and estimates (a
/// packet's barcode in a photo brings its real numbers); one on its way sits at the top of Meals until Coach is
/// done. Tap a meal for its page (fix it there, or ask Coach to); long-press to delete. Every meal also goes to Apple Health (`HealthService.writeMeals`). The Control Center
/// buttons and `aide://meal/…` open it.
struct FoodPage: View {
    @Binding var day: Date

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var health: HealthService

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
    /// The meal being logged, shown at the top of Meals until Coach is done.
    @State private var pending: PendingMeal?
    /// Bumped on each reload of the day, so the week's rings catch up.
    @State private var reloads = 0
    #if DEBUG
    /// Simulator screenshots only: `-previewFood score` opens the day's score page.
    @State private var previewScore = false
    #endif

    private var coach: Agent { chat.agent("coach") }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FoodWeek(day: $day, tint: coach.tint, reload: reloads)
                if noFood {
                    Text("This server doesn't keep a food log yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .card()
                } else {
                    if let food {
                        NavigationLink { NutritionDayView(day: food, tint: coach.tint) } label: {
                            HStack(spacing: 8) {
                                DayScoreCard(day: food, isToday: isToday, tint: coach.tint)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.primary)
                            .card(padding: 14)
                        }
                        .buttonStyle(CardPress())
                    }
                    foodCard
                    logButton
                    mealsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .pageColumn()
            .animation(.easeInOut(duration: 0.25), value: pending)
        }
        .previewAnchor()
        #if DEBUG
        .navigationDestination(isPresented: $previewScore) {
            if let food { NutritionDayView(day: food, tint: coach.tint) }
        }
        #endif
        .sheet(isPresented: $showGoals, onDismiss: { Task { await loadFood() } }) {
            NavigationStack { NutritionTargetsView(inSheet: true) }
        }
        .sheet(item: $editingMeal) { meal in
            MealPage(meal: meal, coach: coach, save: { await update(meal, $0) }, delete: { await remove(meal) },
                     askCoach: openFoodChat)
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

    /// The day's calories and macros, what Coach said of the last meal, and the way to the targets and the chat.
    private var foodCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            FoodSummary(totals: food?.totals ?? FoodTotals(), goals: food?.goals ?? FoodGoals(), tint: coach.tint)
            if pending == nil, let logReply, !logReply.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    AgentMark(agent: coach, size: 26)
                    Text(logReply.markdown).font(.callout)
                }
                .transition(.opacity)
            }
            if let foodError {
                Label(foodError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            Divider()
            HStack {
                if let id = foodChat {
                    Button {
                        push.route = .conversation(id) // the same way a tapped notification opens a chat
                    } label: {
                        Label("Food log chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
                Spacer()
                Button { showGoals = true } label: {
                    HStack(spacing: 3) {
                        Text("Targets")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                }
                .disabled(!settings.isConfigured)
            }
            .font(.subheadline.weight(.semibold))
            .tint(Theme.accent)
            .buttonStyle(.borderless)
        }
        .card()
    }

    /// Three ways in, side by side: a photo (Aide's camera, with the library in it), a few words, or a barcode (the
    /// camera reads it by itself, or type it). Coach (or, for one packet, the server) does the rest.
    private var logButton: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if MealCamera.isAvailable { showCamera = true } else { showLibrary = true }
                } label: {
                    LogTile(title: "Photo", systemImage: "camera.fill", filled: true)
                }
                Button { describing = true } label: {
                    LogTile(title: "Describe", systemImage: "text.cursor", filled: false)
                }
                Menu {
                    if MealCamera.isAvailable {
                        Button("Scan it", systemImage: "barcode.viewfinder") { showCamera = true }
                    }
                    Button("Type the number", systemImage: "number") { typingBarcode = true }
                } label: {
                    LogTile(title: "Barcode", systemImage: "barcode", filled: false)
                }
            }
            .buttonStyle(.plain)
            if !isToday {
                Text("Logging for \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!settings.isConfigured || logging)
    }

    /// The day's meals, newest first, on one card; the one being logged on top.
    private var mealsCard: some View {
        let meals = Meal.newestFirst(food?.meals ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Meals").font(.title3.weight(.bold)).padding(.horizontal, 4).padding(.top, 8)
            VStack(spacing: 0) {
                if let pending {
                    LoggingMealRow(photo: pending.photo, text: pending.text, coach: coach)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if !meals.isEmpty { Divider().padding(.leading, 70) }
                } else if meals.isEmpty {
                    Text(isToday ? "Nothing logged yet today. Take a photo of what you eat, or tell Coach in chat."
                         : "Nothing logged that day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(Array(meals.enumerated()), id: \.element.id) { i, meal in
                    if i > 0 { Divider().padding(.leading, 70) }
                    Button { editingMeal = meal } label: {
                        MealRow(meal: meal).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(RowPress())
                    .accessibilityHint("Opens the meal")
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { if let message = await remove(meal) { foodError = message } }
                        }
                    }
                }
            }
            .background(Theme.row)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
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
            reloads += 1
            #if DEBUG
            // Simulator screenshots: `-previewFood meal`, `score` or `logging`.
            if settings.isPreview, reloads == 1 {
                switch UserDefaults.standard.string(forKey: "previewFood") {
                case "meal": editingMeal = Meal.newestFirst(loaded.meals).first
                case "score": previewScore = true
                case "logging": pending = PendingMeal(photo: nil, text: "a bowl of pasta with tomato and basil")
                default: break
                }
            }
            #endif
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
        withAnimation { pending = PendingMeal(photo: photos.first?.preview, text: text) }
        defer {
            logging = false
            withAnimation { pending = nil } // after the day has reloaded: the row turns into the meal
        }
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

    /// "Ask Coach to fix it" on a meal's page: the Food log chat, else Coach's latest, once the sheet has gone.
    private func openFoodChat() {
        let route: PushRoute = foodChat.map { .conversation($0) } ?? .agent(coach.id)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            push.route = route
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

/// A meal on its way to Coach: its first photo, or the words.
private struct PendingMeal: Equatable {
    let id = UUID()
    let photo: UIImage?
    let text: String?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// One of the Log buttons: an icon over a word, the photo one filled in the accent colour.
private struct LogTile: View {
    let title: String
    let systemImage: String
    let filled: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title3.weight(.semibold)).frame(height: 26)
            Text(title).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(filled ? Theme.onAccent : Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
