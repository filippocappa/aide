import Charts
import SwiftUI

/// What Apple Health says, as the server has it (docs/API.md, "Apple Health"): one number per day and measure.
/// Each is compared with your own usual, the average of the days before (not Apple's baseline, which apps can't see).
enum HealthMetric: String, CaseIterable, Identifiable, Hashable {
    case sleep, sleepHr, restingHr, hrv, breathing, wristTemp, steps, activeKcal, totalKcal, exercise

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sleep: "Sleep"
        case .sleepHr: "Heart rate asleep"
        case .restingHr: "Resting heart rate"
        case .hrv: "Heart rate variability"
        case .breathing: "Breathing rate"
        case .wristTemp: "Wrist temperature"
        case .steps: "Steps"
        case .activeKcal: "Active energy"
        case .totalKcal: "Total energy"
        case .exercise: "Exercise"
        }
    }

    var short: String {
        switch self {
        case .sleepHr: "HR asleep"
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
        case .sleepHr: "bed.double.circle.fill"
        case .restingHr: "heart.fill"
        case .hrv: "waveform.path.ecg"
        case .breathing: "lungs.fill"
        case .wristTemp: "thermometer.medium"
        case .steps: "figure.walk"
        case .activeKcal: "flame.fill"
        case .totalKcal: "bolt.fill"
        case .exercise: "figure.run"
        }
    }

    /// The night's numbers in sleep's colour, the day's in strain's: two hues for the whole of Health.
    var color: Color {
        switch self {
        case .sleep, .sleepHr, .restingHr, .hrv, .breathing, .wristTemp: ScoreColors.sleep[1]
        case .steps, .activeKcal, .totalKcal, .exercise: ScoreColors.strain[1]
        }
    }

    /// What it says, in a line, under the chart.
    var about: String {
        switch self {
        case .sleep: "Time asleep in the night that ended that morning, from your Watch. Naps are counted apart."
        case .sleepHr: "Your average heart rate while asleep, awake stretches left out: what recovery reads. Lower than usual often means well rested."
        case .restingHr: "Apple's resting heart rate for the day, worked out mostly while you're awake. Recovery reads your heart rate asleep instead."
        case .hrv: "The average variability during the night's sleep. Higher than usual usually means recovered."
        case .breathing: "Breaths per minute, averaged over the night."
        case .wristTemp: "Averaged over the night. Up more than half a degree on usual, with resting heart rate up and HRV down, can mean you're getting sick."
        case .steps: "Every step from 00:00 to 24:00."
        case .activeKcal: "Calories burned moving, on top of what your body burns at rest."
        case .totalKcal: "Everything you burned: what your body uses at rest plus what you burned moving, from Apple Health."
        case .exercise: "Minutes of brisk activity: Apple's green ring."
        }
    }

    /// Read over the night, not the day.
    var nightly: Bool { [.sleep, .sleepHr, .hrv, .breathing, .wristTemp].contains(self) }

    /// Daily totals are bars; nightly averages are a line.
    var bars: Bool { [.sleep, .steps, .activeKcal, .totalKcal, .exercise].contains(self) }

    /// Up is good (+1), down is good (-1), or neither (0).
    var better: Int {
        switch self {
        case .sleep, .hrv, .steps, .activeKcal, .totalKcal, .exercise: 1
        case .sleepHr, .restingHr: -1
        case .breathing, .wristTemp: 0
        }
    }

    /// A line to aim for on the chart.
    var goal: Double? { self == .sleep ? 7 : nil }

    func value(_ day: HealthDayReading) -> Double? {
        switch self {
        case .sleep: day.sleep.map { Double($0.asleepMin) / 60 }
        case .sleepHr: day.sleepHr.map(Double.init)
        case .restingHr: day.restingHr.map(Double.init)
        case .hrv: day.hrvMs
        case .breathing: day.respiratoryRate
        case .wristTemp: day.wristTempC
        case .steps: day.steps.map(Double.init)
        case .activeKcal: day.activeKcal.map(Double.init)
        case .totalKcal: day.activeKcal.flatMap { a in day.restingKcal.map { Double(a + $0) } }
        case .exercise: day.exerciseMin.map(Double.init)
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .sleep: SleepCard.duration(Int((v * 60).rounded()))
        case .sleepHr, .restingHr: "\(Int(v.rounded())) bpm"
        case .hrv: "\(Int(v.rounded())) ms"
        case .breathing: "\(v.formatted(.number.precision(.fractionLength(1)))) /min"
        case .wristTemp: "\(v.formatted(.number.precision(.fractionLength(2)))) °C"
        case .steps: Int(v.rounded()).formatted()
        case .activeKcal, .totalKcal: "\(Int(v.rounded()).formatted()) kcal"
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
        default: return sign + Int(a.rounded()).formatted() + (self == .hrv ? " ms" : self == .restingHr || self == .sleepHr ? " bpm" : self == .activeKcal || self == .totalKcal ? " kcal" : " min")
        }
    }

    /// Small enough to count as usual.
    func isUsual(_ d: Double) -> Bool {
        switch self {
        case .sleep: abs(d) < 0.25
        case .sleepHr, .restingHr: abs(d) < 2
        case .hrv: abs(d) < 5
        case .breathing: abs(d) < 0.5
        case .wristTemp: abs(d) < 0.2
        case .steps: abs(d) < 1000
        case .activeKcal: abs(d) < 60
        case .totalKcal: abs(d) < 100
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

/// One measure on a card: the latest number, how it sits next to usual, and the last week in small.
struct MetricTile: View {
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
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the chart")
    }

    private func compare(_ l: (day: HealthDayReading, value: Double, usual: Double?)) -> String {
        var when = HealthDayName.of(l.day.date)
        if metric.nightly && when == "Today" { when = "Last night" }
        if !metric.nightly && when == "Today" { return "Today so far" } // half a day, never judged
        guard let usual = l.usual else { return when }
        let d = l.value - usual
        return metric.isUsual(d) ? "\(when) · usual" : "\(when) · \(metric.difference(d))"
    }

    private func tone(_ l: (day: HealthDayReading, value: Double, usual: Double?)) -> Color {
        guard let usual = l.usual, metric.better != 0, !metric.isUsual(l.value - usual),
              metric.nightly || HealthDayName.of(l.day.date) != "Today" else { return .secondary }
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

struct WorkoutRow: View {
    let date: String
    let workout: HealthDayReading.Workout
    /// What it added to the day's strain (docs/API.md, "Scores").
    var strain: Int? = nil

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
                if let strain {
                    Text("+\(strain)% strain").font(.caption.weight(.semibold)).foregroundStyle(ScoreColors.strain[1]).monospacedDigit()
                } else if let k = workout.kcal {
                    Text("\(k) kcal").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
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

/// How much of a metric's page to show: the chosen day, or the 7, 30 or ~180 days up to it.
enum MetricPeriod: String, CaseIterable, Identifiable {
    case day = "d", week = "w", month = "m", half = "6m"

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    #if DEBUG
    /// `-previewMetricPeriod d|w|m|6m` for Simulator screenshots.
    static var preview: MetricPeriod? {
        UserDefaults.standard.string(forKey: "previewMetricPeriod").flatMap(MetricPeriod.init(rawValue:))
    }
    #endif
}

extension HealthMetric {
    /// The smallest spread for the usual range, so a steady past isn't twitchy: the server's for the night numbers
    /// (`scores.vitals`), ours for the day's totals.
    var bandFloor: Double {
        switch self {
        case .sleep: 25.0 / 60
        case .sleepHr: 2
        case .restingHr: 3
        case .hrv: 3
        case .breathing: 0.4
        case .wristTemp: 0.15
        case .steps: 800
        case .activeKcal: 40
        case .totalKcal: 60
        case .exercise: 5
        }
    }

    /// The usual range the server gave with the day's scores, in this metric's units (sleep in hours).
    func band(_ vitals: HealthScores.Vitals?) -> ClosedRange<Double>? {
        guard let vitals else { return nil }
        let v: HealthScores.Vital? = switch self {
        case .sleep: vitals.asleepMin
        case .sleepHr: vitals.sleepHr
        case .restingHr: vitals.restingHr
        case .hrv: vitals.hrvMs
        case .breathing: vitals.respiratoryRate
        case .wristTemp: vitals.wristTempC
        case .steps, .activeKcal, .totalKcal, .exercise: nil
        }
        guard let low = v?.low, let high = v?.high, high >= low else { return nil }
        let scale = self == .sleep ? 1.0 / 60 : 1
        return (low * scale)...(high * scale)
    }

    /// The number and its unit apart, for the page's big number: ("64", "ms"), ("7h12", nil).
    func formatParts(_ v: Double) -> (number: String, unit: String?) {
        switch self {
        case .sleep: (SleepCard.duration(Int((v * 60).rounded())), nil)
        case .sleepHr, .restingHr: ("\(Int(v.rounded()))", "bpm")
        case .hrv: ("\(Int(v.rounded()))", "ms")
        case .breathing: (v.formatted(.number.precision(.fractionLength(1))), "/min")
        case .wristTemp: (v.formatted(.number.precision(.fractionLength(2))), "°C")
        case .steps: (Int(v.rounded()).formatted(), "steps")
        case .activeKcal, .totalKcal: (Int(v.rounded()).formatted(), "kcal")
        case .exercise: ("\(Int(v.rounded()))", "min")
        }
    }

    /// Its name inside a sentence: "HRV", "steps", "heart rate asleep".
    var inSentence: String { self == .hrv ? "HRV" : name.lowercased() }
}

/// The sums behind a metric's page, apart from the views so they can be tested.
enum MetricMath {
    struct Point: Equatable {
        let date: Date
        let value: Double
    }

    /// The days with a value among the `count` days ending at `end`, oldest first.
    static func window(_ days: [HealthDayReading], metric: HealthMetric, end: Date, count: Int,
                       calendar: Calendar = .current) -> [Point] {
        guard let first = calendar.date(byAdding: .day, value: 1 - count, to: end) else { return [] }
        let from = Wire.dayString(first), to = Wire.dayString(end)
        return days.filter { $0.date >= from && $0.date <= to }
            .compactMap { d in Wire.day(d.date).flatMap { date in metric.value(d).map { Point(date: date, value: $0) } } }
            .sorted { $0.date < $1.date }
    }

    /// Weekly averages over the `weeks` calendar weeks up to the one holding `end` (that one only up to `end`), each
    /// dated by its first day, oldest first; weeks without data are left out.
    static func weekly(_ days: [HealthDayReading], metric: HealthMetric, end: Date, weeks: Int = 26,
                       calendar: Calendar = .current) -> [Point] {
        guard let current = calendar.dateInterval(of: .weekOfYear, for: end) else { return [] }
        return (0..<weeks).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -7 * back, to: current.start),
                  let last = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
            let to = min(last, end)
            let count = (calendar.dateComponents([.day], from: start, to: to).day ?? 6) + 1
            let values = window(days, metric: metric, end: to, count: count, calendar: calendar).map(\.value)
            return average(values).map { Point(date: start, value: $0) }
        }
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The average of the 30 days before `day` (the day itself left out), as the sentence compares against.
    static func average30(_ days: [HealthDayReading], metric: HealthMetric, before day: Date,
                          calendar: Calendar = .current) -> Double? {
        guard let end = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
        return average(window(days, metric: metric, end: end, count: 30, calendar: calendar).map(\.value))
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The usual range as the server's `scores.vitals` works it out: the median ± a robust spread (the median absolute
    /// deviation, scaled, at least `floor`); nil under 14 days.
    static func band(_ values: [Double], floor: Double) -> ClosedRange<Double>? {
        guard values.count >= 14 else { return nil }
        let mid = median(values)
        let spread = max(floor, 1.4826 * median(values.map { abs($0 - mid) }))
        return (mid - spread)...(mid + spread)
    }

    /// The usual range from the 60 days before `day`.
    static func band(_ days: [HealthDayReading], metric: HealthMetric, before day: Date,
                     calendar: Calendar = .current) -> ClosedRange<Double>? {
        guard let end = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
        return band(window(days, metric: metric, end: end, count: 60, calendar: calendar).map(\.value),
                    floor: metric.bandFloor)
    }

    /// -1 below the range, 0 in it, +1 above.
    static func place(_ value: Double, in band: ClosedRange<Double>) -> Int {
        value < band.lowerBound ? -1 : value > band.upperBound ? 1 : 0
    }

    /// Out of the usual range on the bad side (either side when neither is better): the only time it's orange.
    static func isOff(_ metric: HealthMetric, value: Double, band: ClosedRange<Double>?) -> Bool {
        guard let band else { return false }
        let p = place(value, in: band)
        return p != 0 && (metric.better == 0 || p * metric.better < 0)
    }

    /// A day's total still adding up: today's steps, energy or exercise, not yet fair to compare.
    static func partial(_ metric: HealthMetric, on day: Date, calendar: Calendar = .current) -> Bool {
        !metric.nightly && calendar.isDateInToday(day)
    }

    /// "Last night's HRV was 64 ms, 12% above your 30-day average and in your usual range."
    static func sentence(_ metric: HealthMetric, value: Double, on day: Date, average: Double?,
                         band: ClosedRange<Double>?, calendar: Calendar = .current) -> String {
        let shown = metric.format(value)
        let plural = metric == .steps
        if partial(metric, on: day, calendar: calendar) {
            let so = "Today's \(metric.inSentence) so far: \(shown)."
            return average.map { so + " Your 30-day average is \(metric.format($0))." } ?? so
        }
        let subject: String
        if calendar.isDateInToday(day) {
            subject = "Last night's \(metric.inSentence)"
        } else if calendar.isDateInYesterday(day) {
            subject = metric.nightly ? "The night before's \(metric.inSentence)" : "Yesterday's \(metric.inSentence)"
        } else {
            subject = "On " + day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) + ", " + metric.inSentence
        }
        var parts: [String] = []
        var side = 0 // where the average part put it: -1 below, 0 close, 1 above
        if let average, average != 0 {
            let d = value - average
            side = metric.isUsual(d) ? 0 : d > 0 ? 1 : -1
            if metric.isUsual(d) {
                parts.append("close to your 30-day average")
            } else if metric == .wristTemp || metric == .breathing {
                parts.append("\(metric.difference(abs(d)).dropFirst()) \(d > 0 ? "above" : "below") your 30-day average")
            } else {
                parts.append("\(Int((abs(d) / average * 100).rounded()))% \(d > 0 ? "above" : "below") your 30-day average")
            }
        }
        var join = " and "
        if let band {
            let p = place(value, in: band)
            if !parts.isEmpty && p != side && p != 0 { join = " but " } // "close to your average but above your usual range"
            parts.append(["below your usual range", "in your usual range", "above your usual range"][p + 1])
        }
        let head = "\(subject) \(plural ? "were" : "was") \(shown)"
        return parts.isEmpty ? head + "." : head + ", " + parts.joined(separator: join) + "."
    }
}

/// One measure's page, for the day chosen on Health: the number and a sentence on top, then the day on a gauge
/// against your usual range, or the 7, 30 or ~180 days up to it as a chart with that range behind; how it compares,
/// what it is, and the days.
struct HealthMetricView: View {
    let metric: HealthMetric
    let day: Date
    /// That day's usual ranges from the server (nil: worked out here from the days).
    let vitals: HealthScores.Vitals?

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    /// Newest first: what the Health page had, then ~8 months fetched on open.
    @State private var days: [HealthDayReading]
    @State private var period: MetricPeriod
    @State private var selected: Date?
    @State private var showAll = false

    init(metric: HealthMetric, days: [HealthDayReading], day: Date, vitals: HealthScores.Vitals?) {
        self.metric = metric
        self.day = day
        self.vitals = vitals
        _days = State(initialValue: days)
        var period = MetricPeriod.month
        #if DEBUG
        period = MetricPeriod.preview ?? period
        #endif
        _period = State(initialValue: period)
    }

    private var reading: HealthDayReading? { days.first { $0.date == Wire.dayString(day) } }

    private var nextReading: HealthDayReading? {
        Calendar.current.date(byAdding: .day, value: 1, to: day).flatMap { next in
            days.first { $0.date == Wire.dayString(next) }
        }
    }

    private var value: Double? { reading.flatMap(metric.value) }

    private var band: ClosedRange<Double>? {
        metric.band(vitals) ?? MetricMath.band(days, metric: metric, before: day)
    }

    private var average30: Double? { MetricMath.average30(days, metric: metric, before: day) }

    private var points: [MetricMath.Point] {
        switch period {
        case .day: []
        case .week: MetricMath.window(days, metric: metric, end: day, count: 7)
        case .month: MetricMath.window(days, metric: metric, end: day, count: 30)
        case .half: MetricMath.weekly(days, metric: metric, end: day)
        }
    }

    private var periodAverage: Double? { MetricMath.average(points.map(\.value)) }

    private var picked: MetricMath.Point? {
        guard let selected else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    /// "Last night", "Today", "Yesterday" or "Thursday 29 October".
    private var dayWord: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return metric.nightly ? "Last night" : "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                top
                Picker("Period", selection: $period) {
                    ForEach(MetricPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 4)
                if period == .day {
                    dayCards
                } else {
                    chartCard
                }
                againstUsual
                if metric == .sleep { nightCard }
                DetailCard("About") {
                    Text(metric.about).font(.subheadline).foregroundStyle(.secondary)
                }
                dayByDay
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .previewAnchor()
        .pageGlow(metric.color)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: picked?.date)
        .onChange(of: period) { selected = nil }
        .task { await load() }
    }

    // MARK: The top

    private var top: some View {
        TopBlock(metric.name, overline: dayWord) {
            if let value {
                let parts = metric.formatParts(value)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.number).font(.system(size: 48).bold()).monospacedDigit()
                    if let unit = parts.unit { Text(unit).font(.title3.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(MetricMath.sentence(metric, value: value, on: day, average: average30, band: band))
                    .foregroundStyle(!MetricMath.partial(metric, on: day) && MetricMath.isOff(metric, value: value, band: band) ? .orange : .secondary)
            } else {
                Text("Nothing from Apple Health that day.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: D

    @ViewBuilder private var dayCards: some View {
        DetailCard(note: band == nil ? "Learning your usual: it takes two weeks of days."
                                     : "The middle is your usual range, from the 60 days before. The line is your 30-day average.") {
            VStack(alignment: .leading, spacing: 12) {
                WideGauge(value: value, low: band?.lowerBound, high: band?.upperBound, average: average30,
                          color: !MetricMath.partial(metric, on: day) && value.map { MetricMath.isOff(metric, value: $0, band: band) } == true ? .orange : .primary,
                          format: metric.format)
            }
            .padding(.vertical, 6)
        }
        if metric == .restingHr || metric == .sleepHr, let reading, reading.hrHourly?.contains(where: { $0 != nil }) == true {
            DetailCard("Heart rate") { DayHeartChart(day: reading, next: nextReading) }
        }
    }

    // MARK: W, M, 6M

    private var chartCard: some View {
        DetailCard(note: sinceNote) {
            VStack(alignment: .leading, spacing: 14) {
                headline
                chart.frame(height: 220)
            }
        }
    }

    /// "Since 21 Aug" when the data starts after the six months' first week.
    private var sinceNote: String? {
        guard period == .half, let first = points.first?.date,
              let start = Calendar.current.date(byAdding: .weekOfYear, value: -25, to: day),
              first > Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start,
              let oldest = days.last(where: { metric.value($0) != nil }).flatMap({ Wire.day($0.date) }) else { return nil }
        return "Since \(oldest.formatted(.dateTime.day().month(.abbreviated))): weekly averages."
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let picked {
                Text(pickedLabel(picked.date).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(metric.format(picked.value)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else if let periodAverage {
                Text(averageLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(metric.format(periodAverage)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else {
                Text("No data in these days").foregroundStyle(.secondary)
            }
        }
        .frame(height: 64, alignment: .bottomLeading)
        .contentTransition(.numericText())
        .animation(.snappy, value: picked?.date)
    }

    private var averageLabel: String {
        switch period {
        case .week: "AVERAGE OF THESE 7 DAYS"
        case .month: "AVERAGE OF THESE 30 DAYS"
        default: "AVERAGE OF THESE 6 MONTHS"
        }
    }

    private func pickedLabel(_ date: Date) -> String {
        period == .half ? "Week of " + date.formatted(.dateTime.day().month(.wide))
                        : date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var unit: Calendar.Component { period == .half ? .weekOfYear : .day }

    /// The chart's span: the window's first day (or week) to the end of the chosen day (or its week).
    private var domain: ClosedRange<Date> {
        let cal = Calendar.current
        switch period {
        case .half:
            let week = cal.dateInterval(of: .weekOfYear, for: day)
            let start = week.flatMap { cal.date(byAdding: .weekOfYear, value: -25, to: $0.start) } ?? day
            return start...(week?.end ?? day)
        default:
            let count = period == .week ? 7 : 30
            let start = cal.date(byAdding: .day, value: 1 - count, to: day) ?? day
            return start...(cal.date(byAdding: .day, value: 1, to: day) ?? day)
        }
    }

    private var chart: some View {
        Chart {
            if let band {
                RectangleMark(xStart: .value("From", domain.lowerBound), xEnd: .value("To", domain.upperBound),
                              yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound))
                    .foregroundStyle(metric.color.opacity(0.12))
            }
            ForEach(points, id: \.date) { p in
                let faded = picked != nil && picked?.date != p.date
                if metric.bars {
                    BarMark(x: .value("Day", p.date, unit: unit), y: .value(metric.name, p.value), width: .ratio(0.6))
                        .foregroundStyle(metric.color.opacity(faded ? 0.3 : 0.85))
                        .cornerRadius(4)
                } else {
                    LineMark(x: .value("Day", p.date, unit: unit), y: .value(metric.name, p.value))
                        .foregroundStyle(metric.color)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.date, unit: unit), y: .value(metric.name, p.value))
                        .foregroundStyle(metric.color.opacity(faded ? 0.3 : 1))
                        .symbolSize(period == .week ? 40 : 18)
                }
            }
            if let periodAverage, picked == nil {
                RuleMark(y: .value("Average", periodAverage))
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
                RuleMark(x: .value("Day", picked.date, unit: unit))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: metric.bars))
        .chartXAxis {
            switch period {
            case .week:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            case .month:
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            default:
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .chartXSelection(value: $selected)
    }

    // MARK: Against your usual

    @ViewBuilder private var againstUsual: some View {
        if value != nil || average30 != nil {
            DetailCard("Against your usual", padding: 0) {
                if let value {
                    let d = average30.map { value - $0 }
                    let warn = !MetricMath.partial(metric, on: day)
                        && (d.map { !metric.isUsual($0) && (metric.better == 0 || $0 * Double(metric.better) < 0) } ?? false)
                    row(dayWord, detail: MetricMath.partial(metric, on: day) ? "So far" : d.map { metric.isUsual($0) ? "About usual" : metric.difference($0) + " on the average" },
                        value: metric.format(value), warn: warn)
                }
                if value != nil, average30 != nil { RowDivider(leading: 16) }
                if let average30 {
                    row("The 30 days before", detail: band.map { "Usual range \(metric.format($0.lowerBound))–\(metric.format($0.upperBound))" },
                        value: metric.format(average30), warn: false)
                }
            }
        }
    }

    private func row(_ title: String, detail: String?, value: String, warn: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(warn ? .orange : .secondary) }
            }
            Spacer()
            Text(value).font(.body.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sleep's night

    /// The chosen night's stages on D, else their average over the period.
    @ViewBuilder private var nightCard: some View {
        let nights: [SleepNight] = period == .day
            ? [reading?.sleep].compactMap { $0 }
            : MetricMath.window(days, metric: metric, end: day, count: period == .week ? 7 : period == .month ? 30 : 182)
                .compactMap { p in days.first { $0.date == Wire.dayString(p.date) }?.sleep }
        let staged = nights.filter { $0.deepMin != nil }
        if !staged.isEmpty {
            let avg = { (k: KeyPath<SleepNight, Int?>) in staged.compactMap { $0[keyPath: k] }.reduce(0, +) / staged.count }
            let rows: [(String, String)] = [
                ("Deep", SleepCard.duration(avg(\.deepMin))), ("Core", SleepCard.duration(avg(\.coreMin))),
                ("REM", SleepCard.duration(avg(\.remMin))), ("Awake", SleepCard.duration(avg(\.awakeMin))),
            ] + [Self.meanTime(staged.compactMap { Wire.parse($0.bedtime) }).map { ("Bedtime", $0) },
                 Self.meanTime(staged.compactMap { Wire.parse($0.wake) }).map { ("Wake", $0) }].compactMap { $0 }
            DetailCard(period == .day ? "The night" : "Average night", padding: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { RowDivider(leading: 16) }
                    row(r.0, detail: nil, value: r.1, warn: false)
                }
            }
        }
    }

    /// The average clock time, around midnight for bedtimes ("00:20", not "12:00").
    static func meanTime(_ dates: [Date]) -> String? {
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

    // MARK: Day by day

    @ViewBuilder private var dayByDay: some View {
        let count = switch period { case .week: 7; case .half: 182; default: 30 }
        let all = Array(MetricMath.window(days, metric: metric, end: day, count: count).reversed())
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DetailCard("Day by day", padding: 0) {
                    ForEach(Array((showAll ? all : Array(all.prefix(14))).enumerated()), id: \.element.date) { i, p in
                        if i > 0 { RowDivider(leading: 16) }
                        row(HealthDayName.of(Wire.dayString(p.date)), detail: nil, value: metric.format(p.value), warn: false)
                    }
                }
                if all.count > 14 && !showAll {
                    Chip(title: "Show all \(all.count)") { withAnimation(.snappy) { showAll = true } }
                }
            }
        }
    }

    // MARK: Loading

    /// About eight months: six for the chart and the 60 days before them for the usual range.
    private func load() async {
        guard settings.isConfigured,
              let from = Calendar.current.date(byAdding: .day, value: -240, to: day) else { return }
        if let loaded = try? await env.api.healthDays(from: from), !loaded.isEmpty { days = loaded }
    }
}
