import SwiftUI

/// The Health tab, one page for a day (today, or an earlier one from the arrows): Strain, Recovery and Sleep as rings
/// (docs/API.md, "Scores"; each opens its page) with the day in a sentence, last night's numbers against your usual
/// range, the day's heart rate and workouts, activity and weight. (Food has its own tab, habits are on Today.)
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
            List {
                Section { DayHeader(day: $day) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                scoreSections
                weightSection
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
            .refreshable {
                await loadBody(upload: true)
                await loadScores()
            }
            .task {
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
                #endif
            }
            .task(id: day) { await loadScores() }
        }
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


}

/// "‹ Today, 30 October ›", for Health and Food: everything below follows it.
struct DayHeader: View {
    @Binding var day: Date

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        HStack {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Day before")
            Spacer()
            VStack(spacing: 0) {
                Text(title).font(.headline)
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
