import SwiftUI

/// The Health tab's parts, Body, Food and Screen (iPhone only), on the switch at the top; the tab opens on the one
/// used last. All three are Coach's.
enum HealthHalf: String { case body, food, screen }

/// The Health tab, for a day (today, or an earlier one from the arrows), in halves; Body and Food share the day. Body:
/// Strain, Recovery and Sleep as rings (docs/API.md, "Scores"; each opens its page) with the day in a sentence, last
/// night's numbers against your usual range, the day's heart rate and workouts, activity and weight. Food: the food
/// page (`FoodPage`). Screen: where the phone's time went (`ScreenView`, its own day, week or month), with Lock now
/// in the corner instead of the camera. The camera in the corner logs a meal from Body or Food. On the Mac, Body only
/// (Food and Screen are their own sections there). Habits are on Today.
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
    /// The Screen half's Locks and limits, also opened from Lock now in the corner.
    @State private var showLocks = false

    @State private var day = Calendar.current.startOfDay(for: Date())
    /// Shared with `ContentView`, which turns it to Food for `aide://food` and the meal buttons.
    @AppStorage("healthHalf") private var half = HealthHalf.body
    private var coach: Agent { chat.agent("coach") }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// The day's recovery colour, as on its page; sleep's while recovery is still learning or missing; none until
    /// the scores come, so it fades in once.
    private var glow: Color? {
        guard let scores else { return nil }
        if let r = scores.recovery, r.calibrating == nil { return ScoreColors.recovery(r.score)[1] }
        return ScoreColors.sleep[1]
    }

    /// The chosen day's reading from Apple Health.
    private var reading: HealthDayReading? { bodyDays?.first { $0.date == Wire.dayString(day) } }

    /// The days up to the chosen one, newest first: the tiles show the chosen day's numbers.
    private var daysUpTo: [HealthDayReading] {
        let shown = Wire.dayString(day)
        return (bodyDays ?? []).filter { $0.date <= shown }
    }

    /// The day after the chosen one, for the evening's sleep on the heart rate.
    private var nextReading: HealthDayReading? {
        Calendar.current.date(byAdding: .day, value: 1, to: day).flatMap { next in
            bodyDays?.first { $0.date == Wire.dayString(next) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                ZStack {
                    // Screen stays loaded under the other halves once Health opens, so its report (slow: iOS reads
                    // the usage hour by hour) is already drawn when you switch to it.
                    let onScreen = half == .screen
                    ScreenView(showLocks: $showLocks)
                        .opacity(onScreen ? 1 : 0)
                        .allowsHitTesting(onScreen)
                        .accessibilityHidden(!onScreen)
                    switch half {
                    case .food:
                        FoodPage(day: $day)
                            .pageGlow(coach.tint, reach: 700)
                    case .body:
                        bodyPage
                    case .screen:
                        EmptyView()
                    }
                }
                #else
                bodyPage
                #endif
            }
            #if os(iOS)
            // The title, the camera and the switch stay put over both halves, so the switch doesn't jump between
            // them; the day under it scrolls with the page.
            .topBar { tabHeader }
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    #if os(iOS)
    /// The title with the camera on its line (it logs a meal from Body or Food; Lock now on Screen), and the
    /// Body · Food · Screen switch.
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            TopBlock("Health") { EmptyView() } trailing: {
                if half == .screen {
                    ScreenLockMenu { showLocks = true }
                } else {
                    cameraButton
                }
            }
            Picker("Show", selection: Binding(get: { half }, set: { h in withAnimation(.snappy) { half = h } })) {
                Text("Body").tag(HealthHalf.body)
                Text("Food").tag(HealthHalf.food)
                Text("Screen").tag(HealthHalf.screen)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var cameraButton: some View {
        Button {
            withAnimation(.snappy) { half = .food }
            env.mealLog = .photo // the food page opens the meal camera
        } label: {
            CornerIcon(systemImage: "camera.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Snap a meal")
        .disabled(!settings.isConfigured)
    }
    #endif

    /// The top of both halves: the day (on the Mac, under the title).
    @ViewBuilder private var header: some View {
        #if os(iOS)
        DayHeader(day: $day)
        #else
        VStack(alignment: .leading, spacing: 12) {
            TopBlock("Health")
            DayHeader(day: $day)
        }
        #endif
    }

    private var bodyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                scoreSections
                weightSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .pageColumn()
        }
        .previewAnchor()
        .pageGlow(glow, reach: 900)
        .navigationDestination(item: $metric) { m in
            HealthMetricView(metric: m, days: bodyDays ?? [], day: day, vitals: scores?.vitals).macPageBack()
        }
        .navigationDestination(item: $scoreKind) { kind in
            if let scores { ScoreDetailView(kind: kind, scores: scores, day: reading, date: day).macPageBack() }
        }
        .navigationDestination(isPresented: $showWeight) { WeightView { await loadWeight() }.macPageBack() }
        .weightEntry(isPresented: $loggingWeight) { await loadWeight() }
        .refreshable {
            await loadBody(upload: true)
            await loadScores()
        }
        .task {
            await loadBody()
            #if DEBUG
            if settings.isPreview, let m = UserDefaults.standard.string(forKey: "previewMetric") {
                if m == "weight" { showWeight = true } else { metric = HealthMetric(rawValue: m) }
            }
            if settings.isPreview, case let back = UserDefaults.standard.integer(forKey: "previewDaysBack"), back > 0,
               let earlier = Calendar.current.date(byAdding: .day, value: -back, to: day) {
                day = earlier
            }
            if settings.isPreview, let k = UserDefaults.standard.string(forKey: "previewScore") {
                scoreKind = ScoreKind(rawValue: k)
            }
            #endif
        }
        .task(id: day) { await loadScores() }
    }

    @ViewBuilder private var scoreSections: some View {
        if scoresLoaded || scores != nil {
            ScoresCard(scores: scores, coach: coach, open: { kind in if scores != nil { scoreKind = kind } },
                       ask: { push.route = .agent(coach.id) })
        } else if bodyError == nil {
            ScoresSkeleton()
        }
        if let bodyError {
            ErrorCard(text: bodyError)
        } else if bodyDays?.isEmpty == true {
            Text("Nothing from Apple Health yet. Turn it on in Settings → Apple Health, and wear your Watch to bed for sleep and recovery.")
                .font(.subheadline).foregroundStyle(.secondary)
                .card()
        }
        let vitals = vitalRows
        if !vitals.isEmpty {
            DetailCard("Last night", note: "The middle of each gauge is your usual range, from the 60 days before.", padding: 0) {
                ForEach(Array(vitals.enumerated()), id: \.element.0) { i, item in
                    if i > 0 { RowDivider(leading: 58) }
                    Button { metric = item.0 } label: {
                        VitalRow(metric: item.0, vital: item.1)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                    .accessibilityHint("Shows the chart")
                }
            }
        }
        if let reading, reading.hrHourly?.contains(where: { $0 != nil }) == true {
            DetailCard("Heart rate") {
                Button { metric = .restingHr } label: {
                    DayHeartChart(day: reading, next: nextReading).contentShape(Rectangle())
                }
                .buttonStyle(CardPress())
                .accessibilityHint("Shows resting heart rate")
            }
        }
        if let workouts = reading?.workouts, !workouts.isEmpty {
            DetailCard("Workouts", padding: 0) {
                ForEach(Array(workouts.enumerated()), id: \.offset) { i, w in
                    if i > 0 { RowDivider(leading: 62) }
                    WorkoutRow(date: reading?.date ?? "", workout: w,
                               strain: scores?.strain?.workouts.first { $0.id == w.id }?.strain)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
        }
        let activity: [HealthMetric] = [.steps, .exercise, .activeKcal, .totalKcal].filter { m in reading.flatMap(m.value) != nil }
        if !activity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Activity").font(.title3.weight(.bold)).padding(.horizontal, 4)
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: activity.count, by: 2)), id: \.self) { i in
                        GridRow {
                            ForEach(activity[i..<min(i + 2, activity.count)]) { m in
                                Button { metric = m } label: { MetricTile(metric: m, days: daysUpTo) }
                                    .buttonStyle(CardPress())
                            }
                            if i + 1 == activity.count { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
            }
        }
    }

    /// Last night's numbers that have a value, with their usual range.
    private var vitalRows: [(HealthMetric, HealthScores.Vital)] {
        guard let v = scores?.vitals else { return [] }
        let all: [(HealthMetric, HealthScores.Vital?)] = [(.hrv, v.hrvMs), (.sleepHr, v.sleepHr),
                                                         (.restingHr, v.sleepHr == nil ? v.restingHr : nil),
                                                         (.breathing, v.respiratoryRate), (.wristTemp, v.wristTempC),
                                                         (.sleep, v.asleepMin)]
        return all.compactMap { m, x in x.flatMap { $0.value != nil ? (m, $0) : nil } }
    }

    @ViewBuilder private var weightSection: some View {
        if let weight, isToday {
            DetailCard("Weight", padding: 0) {
                WeightCard(weight: weight, open: { showWeight = true }, log: { loggingWeight = true })
            }
        }
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

    /// 35 days: the week's change needs the week before it too.
    private func loadWeight() async {
        weight = try? await env.api.weight(days: 35) // nil from a server without weights: no card
    }
}

/// "‹ Today, 30 October ›", for Health and Food: everything below follows it. Tapping the date opens a calendar.
struct DayHeader: View {
    @Binding var day: Date
    @State private var picking = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        HStack {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Day before")
            Spacer()
            Button { picking = true } label: {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(title).font(.headline)
                        Image(systemName: "calendar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if isToday || Calendar.current.isDateInYesterday(day) {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityHint("Opens a calendar")
            Spacer()
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .disabled(isToday)
            .accessibilityLabel("Day after")
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .sheet(isPresented: $picking) {
            DayCalendar(day: $day)
                .presentationDetents([.medium])
        }
    }

    /// "Today", "Yesterday" or "Monday 19 October".
    private var title: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func move(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= Date() else { return }
        withAnimation(.snappy) { day = Calendar.current.startOfDay(for: next) }
    }
}

/// A month calendar to jump to a day (up to today); picking one closes it.
struct DayCalendar: View {
    @Binding var day: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: Binding(get: { day }, set: { picked in
                withAnimation(.snappy) { day = Calendar.current.startOfDay(for: picked) }
                dismiss()
            }), in: ...Date(), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        withAnimation(.snappy) { day = Calendar.current.startOfDay(for: .now) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .sheetDone) { Button("Done") { dismiss() } }
            }
        }
    }
}
