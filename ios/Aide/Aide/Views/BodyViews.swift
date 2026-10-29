import Charts
import SwiftUI

/// What Apple Health says, as the server has it (docs/API.md, "Apple Health"): one number per day and measure.
/// Each is compared with your own usual, the average of the days before (not Apple's baseline, which apps can't see).
enum HealthMetric: String, CaseIterable, Identifiable, Hashable {
    case sleep, restingHr, hrv, breathing, wristTemp, steps, activeKcal, exercise

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sleep: "Sleep"
        case .restingHr: "Resting heart rate"
        case .hrv: "Heart rate variability"
        case .breathing: "Breathing rate"
        case .wristTemp: "Wrist temperature"
        case .steps: "Steps"
        case .activeKcal: "Active energy"
        case .exercise: "Exercise"
        }
    }

    var short: String {
        switch self {
        case .restingHr: "Resting HR"
        case .hrv: "HRV"
        case .breathing: "Breathing"
        case .wristTemp: "Wrist temp"
        default: name
        }
    }

    var icon: String {
        switch self {
        case .sleep: "bed.double.fill"
        case .restingHr: "heart.fill"
        case .hrv: "waveform.path.ecg"
        case .breathing: "lungs.fill"
        case .wristTemp: "thermometer.medium"
        case .steps: "figure.walk"
        case .activeKcal: "flame.fill"
        case .exercise: "figure.run"
        }
    }

    var color: Color {
        switch self {
        case .sleep: .indigo
        case .restingHr, .hrv: .red
        case .breathing: .cyan
        case .wristTemp: .orange
        case .steps: .orange
        case .activeKcal: .pink
        case .exercise: .green
        }
    }

    /// What it says, in a line, under the chart.
    var about: String {
        switch self {
        case .sleep: "Time asleep in the night that ended that morning, from your Watch. Naps are counted apart."
        case .restingHr: "Apple's resting heart rate for the day. Lower than usual often means well rested."
        case .hrv: "The average variability during the night's sleep. Higher than usual usually means recovered."
        case .breathing: "Breaths per minute, averaged over the night."
        case .wristTemp: "Averaged over the night. Up more than half a degree on usual, with resting heart rate up and HRV down, can mean you're getting sick."
        case .steps: "Every step from 00:00 to 24:00."
        case .activeKcal: "Calories burned moving, on top of what your body burns at rest."
        case .exercise: "Minutes of brisk activity: Apple's green ring."
        }
    }

    /// Read over the night, not the day.
    var nightly: Bool { [.sleep, .hrv, .breathing, .wristTemp].contains(self) }

    /// Daily totals are bars; nightly averages are a line.
    var bars: Bool { [.sleep, .steps, .activeKcal, .exercise].contains(self) }

    /// Up is good (+1), down is good (-1), or neither (0).
    var better: Int {
        switch self {
        case .sleep, .hrv, .steps, .activeKcal, .exercise: 1
        case .restingHr: -1
        case .breathing, .wristTemp: 0
        }
    }

    /// A line to aim for on the chart.
    var goal: Double? { self == .sleep ? 7 : nil }

    func value(_ day: HealthDayReading) -> Double? {
        switch self {
        case .sleep: day.sleep.map { Double($0.asleepMin) / 60 }
        case .restingHr: day.restingHr.map(Double.init)
        case .hrv: day.hrvMs
        case .breathing: day.respiratoryRate
        case .wristTemp: day.wristTempC
        case .steps: day.steps.map(Double.init)
        case .activeKcal: day.activeKcal.map(Double.init)
        case .exercise: day.exerciseMin.map(Double.init)
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .sleep: SleepCard.duration(Int((v * 60).rounded()))
        case .restingHr: "\(Int(v.rounded())) bpm"
        case .hrv: "\(Int(v.rounded())) ms"
        case .breathing: "\(v.formatted(.number.precision(.fractionLength(1)))) /min"
        case .wristTemp: "\(v.formatted(.number.precision(.fractionLength(2)))) °C"
        case .steps: Int(v.rounded()).formatted()
        case .activeKcal: "\(Int(v.rounded())) kcal"
        case .exercise: "\(Int(v.rounded())) min"
        }
    }

    /// "+4 bpm", "−0.3 °C", "+25m": how far from usual.
    func difference(_ d: Double) -> String {
        let sign = d < 0 ? "−" : "+"
        let a = abs(d)
        switch self {
        case .sleep: return sign + SleepCard.duration(Int((a * 60).rounded()))
        case .wristTemp: return sign + "\(a.formatted(.number.precision(.fractionLength(1)))) °C"
        case .breathing: return sign + a.formatted(.number.precision(.fractionLength(1)))
        case .steps: return sign + Int(a.rounded()).formatted()
        default: return sign + "\(Int(a.rounded()))" + (self == .hrv ? " ms" : self == .restingHr ? " bpm" : self == .activeKcal ? " kcal" : " min")
        }
    }

    /// Small enough to count as usual.
    func isUsual(_ d: Double) -> Bool {
        switch self {
        case .sleep: abs(d) < 0.25
        case .restingHr: abs(d) < 2
        case .hrv: abs(d) < 5
        case .breathing: abs(d) < 0.5
        case .wristTemp: abs(d) < 0.2
        case .steps: abs(d) < 1000
        case .activeKcal: abs(d) < 60
        case .exercise: abs(d) < 8
        }
    }

    /// The newest day that has it, and how it compares with the average of the days before it.
    func latest(in days: [HealthDayReading]) -> (day: HealthDayReading, value: Double, usual: Double?)? {
        guard let i = days.firstIndex(where: { value($0) != nil }), let v = value(days[i]) else { return nil }
        let before = days[(i + 1)...].compactMap(value)
        return (days[i], v, before.count >= 3 ? before.reduce(0, +) / Double(before.count) : nil)
    }
}

/// "Today", "Yesterday" or "Mon 19 Oct".
enum HealthDayName {
    static func of(_ date: String) -> String {
        guard let d = Wire.day(date) else { return date }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// The Body page of the Health tab: last night, recovery, today's activity, weight and recent workouts, each opening its
/// chart.
struct BodySections: View {
    /// Newest first; nil while loading.
    let days: [HealthDayReading]?
    let error: String?
    /// The weight readings and trend; nil while loading, or from a server without them.
    var weight: WeightList? = nil
    let open: (HealthMetric) -> Void
    var openWeight: () -> Void = {}
    var logWeight: () -> Void = {}

    var body: some View {
        if let days, !days.isEmpty {
            sleep(days)
            recovery(days)
            activity(days)
            weightSection
            workouts(days)
        } else if let error {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
        } else if days != nil {
            Section {
                Text("Nothing from Apple Health yet. Turn it on in Settings → Apple Health, and wear your Watch to bed for sleep and recovery.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            SkeletonSections(sections: 3, rows: 1, mark: false)
        }
    }

    /// "Nap 10:42–12:30 (1h40)".
    private static func nap(_ nap: SleepNap) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let span = [nap.start, nap.end].compactMap(Wire.parse).map { $0.formatted(time) }.joined(separator: "–")
        return "Nap \(span) (\(SleepCard.duration(nap.asleepMin)))"
    }

    @ViewBuilder private func sleep(_ days: [HealthDayReading]) -> some View {
        if let night = days.first(where: { $0.sleep != nil }), let s = night.sleep {
            let usual = HealthMetric.sleep.latest(in: days)?.usual.map { Int(($0 * 60).rounded()) }
            Section {
                Button { open(.sleep) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        SleepCard(night: s, usualAsleepMin: usual)
                        if let naps = days.first?.naps, !naps.isEmpty {
                            Label(naps.map(Self.nap).joined(separator: ", "), systemImage: "powersleep")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        MiniChart(metric: .sleep, days: Array(days.prefix(7)))
                            .frame(height: 44)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                header(Self.isToday(night.date) ? "Last night" : "Sleep, \(HealthDayName.of(night.date))",
                       icon: "moon.zzz.fill", color: .indigo)
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func recovery(_ days: [HealthDayReading]) -> some View {
        let metrics: [HealthMetric] = [.hrv, .restingHr, .breathing, .wristTemp].filter { $0.latest(in: days) != nil }
        if !metrics.isEmpty {
            Section {
                tiles(metrics, days)
            } header: {
                header("Recovery", icon: "heart.text.square.fill", color: .red)
            } footer: {
                Text("Last night's numbers next to your own usual, the average of the days before.")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder private func activity(_ days: [HealthDayReading]) -> some View {
        let metrics: [HealthMetric] = [.steps, .activeKcal, .exercise].filter { $0.latest(in: days) != nil }
        if !metrics.isEmpty {
            Section {
                tiles(metrics, days)
            } header: {
                header("Activity", icon: "figure.walk", color: .orange)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder private var weightSection: some View {
        if let weight {
            Section {
                WeightCard(weight: weight, open: openWeight, log: logWeight)
            } header: {
                header("Weight", icon: "scalemass.fill", color: WeightSummary.color)
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func workouts(_ days: [HealthDayReading]) -> some View {
        let recent = days.prefix(14).flatMap { day in (day.workouts ?? []).map { (day.date, $0) } }
        if !recent.isEmpty {
            Section {
                ForEach(Array(recent.prefix(8).enumerated()), id: \.offset) { _, item in
                    WorkoutRow(date: item.0, workout: item.1)
                }
            } header: {
                header("Workouts", icon: "dumbbell.fill", color: .green)
            } footer: {
                Text("The last two weeks. A workout can tick a habit: set it on the habit.")
            }
            .listRowBackground(Theme.row)
        }
    }

    private func tiles(_ metrics: [HealthMetric], _ days: [HealthDayReading]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(metrics) { m in
                Button { open(m) } label: { MetricTile(metric: m, days: days) }
                    .buttonStyle(CardPress())
            }
        }
        .padding(.vertical, 2)
    }

    private func header(_ title: String, icon: String, color: Color) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
    }

    private static func isToday(_ date: String) -> Bool { Wire.day(date).map(Calendar.current.isDateInToday) ?? false }
}

/// One measure on a card: the latest number, how it sits next to usual, and the last week in small.
private struct MetricTile: View {
    let metric: HealthMetric
    let days: [HealthDayReading]

    var body: some View {
        let latest = metric.latest(in: days)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: metric.icon).foregroundStyle(metric.color)
                Text(metric.short).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.semibold))
            if let latest {
                Text(metric.format(latest.value))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(compare(latest))
                    .font(.caption)
                    .foregroundStyle(tone(latest))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            MiniChart(metric: metric, days: Array(days.prefix(7)))
                .frame(height: 30)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the chart")
    }

    private func compare(_ l: (day: HealthDayReading, value: Double, usual: Double?)) -> String {
        var when = HealthDayName.of(l.day.date)
        if metric.nightly && when == "Today" { when = "Last night" }
        guard let usual = l.usual else { return when }
        let d = l.value - usual
        return metric.isUsual(d) ? "\(when) · usual" : "\(when) · \(metric.difference(d))"
    }

    private func tone(_ l: (day: HealthDayReading, value: Double, usual: Double?)) -> Color {
        guard let usual = l.usual, metric.better != 0, !metric.isUsual(l.value - usual) else { return .secondary }
        return (l.value - usual) * Double(metric.better) > 0 ? .green : .orange
    }
}

/// The last few days in small: bars or a line, oldest on the left.
private struct MiniChart: View {
    let metric: HealthMetric
    /// Newest first.
    let days: [HealthDayReading]

    var body: some View {
        let points = days.reversed().compactMap { d in Wire.day(d.date).flatMap { day in metric.value(d).map { (day, $0) } } }
        Chart {
            ForEach(points, id: \.0) { day, v in
                if metric.bars {
                    BarMark(x: .value("Day", day, unit: .day), y: .value(metric.name, v), width: .ratio(0.55))
                        .foregroundStyle(metric.color.opacity(Calendar.current.isDateInToday(day) ? 1 : 0.55))
                        .cornerRadius(3)
                } else {
                    LineMark(x: .value("Day", day, unit: .day), y: .value(metric.name, v))
                        .foregroundStyle(metric.color)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", day, unit: .day), y: .value(metric.name, v))
                        .foregroundStyle(metric.color)
                        .symbolSize(14)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: metric.bars))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkoutRow: View {
    let date: String
    let workout: HealthDayReading.Workout

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(workout.type))
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(Color.green.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(workout.type)).font(.body.weight(.medium))
                Text(when).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let m = workout.minutes { Text("\(m) min").monospacedDigit() }
                if let k = workout.kcal { Text("\(k) kcal").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var when: String {
        let day = HealthDayName.of(date)
        guard let start = workout.start.flatMap(Wire.parse) else { return day }
        return "\(day), \(start.formatted(date: .omitted, time: .shortened))"
    }

    static func name(_ type: String) -> String {
        switch type {
        case "hiit": return "HIIT"
        case "martial_arts": return "Martial arts"
        case "sport": return "Sport"
        default:
            let t = type.replacingOccurrences(of: "_", with: " ")
            return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    static func icon(_ type: String) -> String {
        switch type {
        case "strength": "dumbbell.fill"
        case "run": "figure.run"
        case "walk": "figure.walk"
        case "hike": "figure.hiking"
        case "cycle": "figure.outdoor.cycle"
        case "swim": "figure.pool.swim"
        case "hiit": "figure.highintensity.intervaltraining"
        case "yoga": "figure.yoga"
        case "pilates": "figure.pilates"
        case "core": "figure.core.training"
        case "dance": "figure.dance"
        case "climb": "figure.climbing"
        case "row": "figure.rower"
        case "elliptical": "figure.elliptical"
        case "stairs": "figure.stair.stepper"
        case "martial_arts": "figure.martial.arts"
        case "sport": "sportscourt.fill"
        default: "figure.mixed.cardio"
        }
    }
}

/// One measure over 7 or 30 days: the chart (touch it to read a day), the average, usual and the days in a list.
struct HealthMetricView: View {
    let metric: HealthMetric
    /// Newest first.
    let days: [HealthDayReading]
    @State private var range = 7
    @State private var selected: Date?

    private var shown: [(date: Date, value: Double, day: HealthDayReading)] {
        days.prefix(range).reversed().compactMap { d in
            guard let date = Wire.day(d.date), let v = metric.value(d) else { return nil }
            return (date, v, d)
        }
    }

    private var average: Double? {
        let values = shown.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private var picked: (date: Date, value: Double, day: HealthDayReading)? {
        guard let selected else { return nil }
        return shown.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    headline
                    chart.frame(height: 220)
                }
                .padding(.vertical, 8)
            } footer: {
                Text(metric.about)
            }
            .listRowBackground(Theme.row)

            if metric == .sleep {
                stages
            }

            Section("Day by day") {
                ForEach(shown.reversed(), id: \.date) { item in
                    LabeledContent(HealthDayName.of(item.day.date)) {
                        Text(metric.format(item.value)).monospacedDigit()
                    }
                }
            }
            .listRowBackground(Theme.row)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(metric.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: picked?.date)
    }

    /// The touched day, or the range's average.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let picked {
                Text(picked.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(metric.format(picked.value)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else if let average {
                Text(range == 7 ? "AVERAGE, LAST 7 DAYS" : "AVERAGE, LAST 30 DAYS")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(metric.format(average)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else {
                Text("No data in these days").foregroundStyle(.secondary)
            }
        }
        .frame(height: 64, alignment: .bottomLeading)
        .contentTransition(.numericText())
        .animation(.snappy, value: picked?.date)
    }

    private var chart: some View {
        Chart {
            ForEach(shown, id: \.date) { item in
                let faded = picked != nil && picked?.date != item.date
                if metric.bars {
                    BarMark(x: .value("Day", item.date, unit: .day), y: .value(metric.name, item.value))
                        .foregroundStyle(metric.color.opacity(faded ? 0.3 : 0.85))
                        .cornerRadius(4)
                } else {
                    LineMark(x: .value("Day", item.date, unit: .day), y: .value(metric.name, item.value))
                        .foregroundStyle(metric.color)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", item.date, unit: .day), y: .value(metric.name, item.value))
                        .foregroundStyle(metric.color.opacity(faded ? 0.3 : 1))
                        .symbolSize(range == 7 ? 40 : 18)
                }
            }
            if let average, picked == nil {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let goal = metric.goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(metric.color.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(Int(goal))h").font(.caption2).foregroundStyle(metric.color)
                    }
            }
            if let picked {
                RuleMark(x: .value("Day", picked.date, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: .automatic(includesZero: metric.bars))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: range == 7 ? .dateTime.weekday(.narrow) : .dateTime.day().month(.abbreviated))
            }
        }
        .chartXSelection(value: $selected)
    }

    /// Sleep stages, averaged over the nights that have them.
    @ViewBuilder private var stages: some View {
        let nights = shown.compactMap(\.day.sleep).filter { $0.deepMin != nil }
        if !nights.isEmpty {
            let avg = { (k: KeyPath<SleepNight, Int?>) in nights.compactMap { $0[keyPath: k] }.reduce(0, +) / nights.count }
            let bed = nights.compactMap { Wire.parse($0.bedtime) }
            let wake = nights.compactMap { Wire.parse($0.wake) }
            Section("Average night") {
                LabeledContent("Deep", value: SleepCard.duration(avg(\.deepMin)))
                LabeledContent("Core", value: SleepCard.duration(avg(\.coreMin)))
                LabeledContent("REM", value: SleepCard.duration(avg(\.remMin)))
                LabeledContent("Awake", value: SleepCard.duration(avg(\.awakeMin)))
                if let b = Self.meanTime(bed) { LabeledContent("Bedtime", value: b) }
                if let w = Self.meanTime(wake) { LabeledContent("Wake", value: w) }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// The average clock time, around midnight for bedtimes ("00:20", not "12:00").
    private static func meanTime(_ dates: [Date]) -> String? {
        guard !dates.isEmpty else { return nil }
        let cal = Calendar.current
        let mins = dates.map { d -> Int in
            let c = cal.dateComponents([.hour, .minute], from: d)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            return m < 12 * 60 ? m + 24 * 60 : m // after noon stays, the small hours count as the night before's
        }
        let mean = (mins.reduce(0, +) / mins.count) % (24 * 60)
        return String(format: "%02d:%02d", mean / 60, mean % 60)
    }
}
