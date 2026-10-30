import Charts
import SwiftUI

/// The three Health scores (docs/API.md, "Scores"), worked out on the server against your own past.
enum ScoreKind: String, CaseIterable, Identifiable, Hashable {
    case strain, recovery, sleep

    var id: String { rawValue }

    var name: String {
        switch self {
        case .strain: "Strain"
        case .recovery: "Recovery"
        case .sleep: "Sleep"
        }
    }

    var icon: String {
        switch self {
        case .strain: "flame.fill"
        case .recovery: "heart.fill"
        case .sleep: "moon.fill"
        }
    }

    func score(_ s: HealthScores?) -> Int? {
        switch self {
        case .strain: s?.strain?.score
        case .recovery: s?.recovery?.score
        case .sleep: s?.sleep?.score
        }
    }

    func score(_ d: ScoreDay) -> Int? {
        switch self {
        case .strain: d.strain
        case .recovery: d.recovery
        case .sleep: d.sleep
        }
    }

    func colors(_ score: Int?) -> [Color] {
        switch self {
        case .strain: ScoreColors.strain
        case .recovery: ScoreColors.recovery(score)
        case .sleep: ScoreColors.sleep
        }
    }

    /// Under the ring: the strain target, recovery in a word, sleep against the need.
    func caption(_ s: HealthScores?) -> String {
        switch self {
        case .strain:
            if let t = s?.strain?.target, t.count == 2 { return "Aim \(t[0])–\(t[1])" }
            return s?.strain?.estimated == true ? "Estimated" : " "
        case .recovery:
            if let c = s?.recovery?.calibrating { return "Calibrating \(c.days)/\(c.needs)" }
            return Self.word(s?.recovery?.level) ?? " "
        case .sleep:
            guard let sleep = s?.sleep, let asleep = sleep.asleepMin else { return " " }
            return "\(hm(asleep)) of \(hm(sleep.needMin))"
        }
    }

    static func word(_ level: String?) -> String? {
        switch level {
        case "good": "Recovered"
        case "normal": "Normal"
        case "low": "Take it easy"
        default: nil
        }
    }

    /// How it's worked out, in a few lines, at the bottom of its page.
    var about: String {
        switch self {
        case .strain:
            "How hard your heart worked today: time with your heart rate well above rest, weighted by how high it went (Banister's TRIMP), on a 0–100 scale that gets harder to fill near the top. Recovery sets the day's target band."
        case .recovery:
            "Last night's heart rate variability (half of it), resting heart rate and sleep score, each against your own usual over the 60 days before. A usual night lands in the 60s. Breathing rate or wrist temperature well above usual holds it at 50. Not medical advice."
        case .sleep:
            "Hours asleep against what you needed (7h30, plus half of what the last three nights were short, at most an hour more), deep and REM sleep, time asleep in bed, and how close bedtime was to your usual."
        }
    }
}

/// "7h53"
private func hm(_ minutes: Int) -> String { "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }

/// A score in a gradient ring, with the strain target as a faint arc on the track.
struct ScoreDial: View {
    let kind: ScoreKind
    let score: Int?
    var band: [Int]? = nil
    var size: CGFloat = 88

    private var width: CGFloat { size * 0.11 }

    var body: some View {
        let colors = kind.colors(score)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: width)
            if let band, band.count == 2 {
                Circle()
                    .trim(from: Double(band[0]) / 100, to: Double(band[1]) / 100)
                    .stroke(colors[1].opacity(0.28), style: StrokeStyle(lineWidth: width, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if let score, score > 0 {
                let part = Double(score) / 100
                Circle()
                    .trim(from: 0, to: part)
                    .stroke(AngularGradient(colors: colors, center: .center,
                                            startAngle: .zero, endAngle: .degrees(360 * part)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                if score != nil {
                    Text("%").font(.system(size: size * 0.14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.name) \(score.map { "\($0) percent" } ?? "not yet")")
    }
}

/// On top of Health: the three rings, each opening its page, and the day in a sentence (tap: Coach).
struct ScoresCard: View {
    let scores: HealthScores?
    let coach: Agent
    let open: (ScoreKind) -> Void
    let ask: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(ScoreKind.allCases) { kind in
                    Button { open(kind) } label: {
                        VStack(spacing: 8) {
                            ScoreDial(kind: kind, score: kind.score(scores),
                                      band: kind == .strain ? scores?.strain?.target : nil)
                            VStack(spacing: 1) {
                                Text(kind.name).font(.subheadline.weight(.semibold))
                                Text(kind.caption(scores)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CardPress())
                    .accessibilityHint("Shows what it's made of")
                }
            }
            if let line = scores?.line {
                Divider()
                Button(action: ask) {
                    HStack(alignment: .top, spacing: 10) {
                        AgentMark(agent: coach, size: 24)
                        Text(line).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your chat with \(coach.name)")
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Vitals

/// Last night's numbers, each on a gauge with your usual range in the middle.
struct VitalRow: View {
    let metric: HealthMetric
    let vital: HealthScores.Vital

    /// Sleep comes in minutes; the metric speaks hours.
    private var scale: Double { metric == .sleep ? 1.0 / 60 : 1 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: metric.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(metric.color)
                .frame(width: 30, height: 30)
                .background(metric.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.short).font(.subheadline.weight(.medium))
                Text(compare).font(.caption).foregroundStyle(tone).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let v = vital.value {
                Text(metric.format(v * scale)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            RangeGauge(value: vital.value, low: vital.low, high: vital.high, color: tone == .secondary ? metric.color : tone)
                .frame(width: 64, height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var place: Int? {
        guard let v = vital.value, let low = vital.low, let high = vital.high else { return nil }
        return v < low ? -1 : v > high ? 1 : 0
    }

    private var compare: String {
        guard let place, let usual = vital.usual else { return "Learning your usual" }
        if place == 0 { return "In your usual range" }
        return "\(place > 0 ? "↑" : "↓") usual \(metric.format(usual * scale))"
    }

    private var tone: Color {
        guard let place, place != 0 else { return .secondary }
        if metric.better == 0 { return .orange }
        return place * metric.better > 0 ? .green : .orange
    }
}

/// A capsule: the usual range in the middle third, a dot where the value sits.
struct RangeGauge: View {
    let value: Double?
    let low: Double?
    let high: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if low != nil {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: w / 3).offset(x: w / 3)
                }
                if let x = position {
                    Circle().fill(color)
                        .overlay(Circle().stroke(Theme.row, lineWidth: 2))
                        .frame(width: geo.size.height + 4, height: geo.size.height + 4)
                        .offset(x: x * w - (geo.size.height + 4) / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0…1 along the gauge: the range is 1/3…2/3, a range's width either side fills the rest.
    private var position: Double? {
        guard let value else { return nil }
        guard let low, let high, high > low else { return 0.5 }
        return min(0.97, max(0.03, (value - low) / (high - low) / 3 + 1.0 / 3))
    }
}

// MARK: - The day's heart rate

/// Hourly heart rate over the day, the night's sleep shaded, workouts marked.
struct DayHeartChart: View {
    let day: HealthDayReading

    private var start: Date? { Wire.day(day.date) }

    private var points: [(Date, Int)] {
        guard let start, let hourly = day.hrHourly else { return [] }
        return hourly.enumerated().compactMap { h, bpm in
            bpm.map { (start.addingTimeInterval(Double(h) * 3600 + 1800), $0) }
        }
    }

    private var workouts: [(Date, Date)] {
        (day.workouts ?? []).compactMap { w in
            guard let s = w.start.flatMap(Wire.parse) else { return nil }
            let e = w.end.flatMap(Wire.parse) ?? s.addingTimeInterval(Double((w.minutes ?? 30) * 60))
            return (s, e)
        }
    }

    var body: some View {
        let red = Color(uiColor: UIColor(hex: 0xFF453A))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let top = day.maxHr {
                    Text("Up to \(top) bpm").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                HStack(spacing: 12) {
                    legend(.indigo, "Asleep")
                    if !workouts.isEmpty { legend(ScoreColors.strain[1], "Workout") }
                }
            }
            Chart {
                if let start, let wake = day.sleep?.wakeDate, wake > start {
                    RectangleMark(xStart: .value("From", start), xEnd: .value("To", wake))
                        .foregroundStyle(Color.indigo.opacity(0.10))
                }
                ForEach(Array(workouts.enumerated()), id: \.offset) { _, w in
                    RectangleMark(xStart: .value("From", w.0), xEnd: .value("To", w.1))
                        .foregroundStyle(ScoreColors.strain[1].opacity(0.18))
                }
                ForEach(points, id: \.0) { time, bpm in
                    AreaMark(x: .value("Time", time), y: .value("bpm", bpm))
                        .foregroundStyle(LinearGradient(colors: [red.opacity(0.25), red.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", time), y: .value("bpm", bpm))
                        .foregroundStyle(red)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: (start ?? Date())...((start ?? Date()).addingTimeInterval(86_400)))
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 140)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate through the day" + (day.maxHr.map { ", up to \($0) beats a minute" } ?? ""))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.5)).frame(width: 10, height: 10)
            Text(text)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - A score's page

/// One score: the big ring, what it's made of, and the last 30 days.
struct ScoreDetailView: View {
    let kind: ScoreKind
    /// The day as Apple Health has it (the night, workouts); nil when not loaded.
    let day: HealthDayReading?
    let date: Date

    @EnvironmentObject private var env: AppEnvironment
    /// What the Health page had, then the day's own, fetched again on open.
    @State private var scores: HealthScores
    @State private var history: [ScoreDay]?

    init(kind: ScoreKind, scores: HealthScores, day: HealthDayReading?, date: Date) {
        self.kind = kind
        self.day = day
        self.date = date
        _scores = State(initialValue: scores)
    }
    @State private var selected: Date?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ScoreDial(kind: kind, score: kind.score(scores),
                              band: kind == .strain ? scores.strain?.target : nil, size: 168)
                    Text(headline).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    if let sub = subline {
                        Text(sub).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Theme.row)

            switch kind {
            case .recovery: recoverySections
            case .sleep: sleepSections
            case .strain: strainSections
            }

            Section {
                trend
            } header: {
                Text("Last 30 days")
            } footer: {
                Text(kind.about)
            }
            .listRowBackground(Theme.row)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let fresh = try? env.api.healthScores(date: date)
            history = (try? await env.api.healthScoreHistory(days: 30, to: date)) ?? []
            if let fresh = await fresh { scores = fresh }
        }
    }

    private var headline: String {
        switch kind {
        case .recovery:
            if let c = scores.recovery?.calibrating { return "Calibrating: \(c.days) of \(c.needs) days" }
            return ScoreKind.word(scores.recovery?.level) ?? "No recovery yet"
        case .sleep:
            guard let s = scores.sleep else { return "No night recorded" }
            return s.asleepMin.map { "\(hm($0)) asleep" } ?? "Sleep \(s.score)%"
        case .strain:
            guard let s = scores.strain else { return "No data for the day" }
            guard let t = s.target, t.count == 2 else { return s.score == 0 ? "A rest day so far" : "Strain \(s.score)%" }
            if s.score < t[0] { return "Below the target" }
            return s.score > t[1] ? "Over the target" : "In the target"
        }
    }

    private var subline: String? {
        switch kind {
        case .recovery:
            if scores.recovery?.calibrating != nil {
                return "Recovery needs two weeks of nights with HRV to learn your usual."
            }
            return scores.line
        case .sleep:
            guard let s = scores.sleep else { return nil }
            return "You needed \(hm(s.needMin)) last night."
        case .strain:
            guard let s = scores.strain else { return nil }
            var out = s.target.map { $0.count == 2 ? "Target \($0[0])–\($0[1])% from your recovery." : "" } ?? ""
            if s.estimated { out += (out.isEmpty ? "" : " ") + "Estimated from workouts until heart rate comes from the phone." }
            return out.isEmpty ? nil : out
        }
    }

    // MARK: Recovery

    @ViewBuilder private var recoverySections: some View {
        if let r = scores.recovery {
            if !r.flags.isEmpty {
                Section {
                    ForEach(r.flags, id: \.self) { flag in
                        Label(flag == "wrist_temp" ? "Wrist temperature above your usual" : "Breathing rate above your usual",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Either can mean your body is fighting something, so recovery is held at 50% at most.")
                }
                .listRowBackground(Theme.row)
            }
            if !r.contributors.isEmpty {
                Section("What it's made of") {
                    ForEach(r.contributors) { PartRow(part: $0, color: kind.colors(r.score)[1]) }
                }
                .listRowBackground(Theme.row)
            }
        }
    }

    // MARK: Sleep

    @ViewBuilder private var sleepSections: some View {
        if let night = day?.sleep {
            Section("Last night") {
                SleepCard(night: night, usualAsleepMin: scores.vitals?.asleepMin?.usual.map { Int($0) })
                    .padding(.vertical, 4)
            }
            .listRowBackground(Theme.row)
        }
        if let s = scores.sleep {
            Section("What it's made of") {
                ForEach(s.contributors) { PartRow(part: $0, color: ScoreColors.sleep[1]) }
            }
            .listRowBackground(Theme.row)
            Section {
                LabeledContent("Needed", value: hm(s.needMin))
                LabeledContent("Short, last 3 nights", value: s.debtMin > 0 ? hm(s.debtMin) : "Nothing")
            } header: {
                Text("Sleep need")
            } footer: {
                Text("Half of what you were short over the last three nights is added to the next night's 7h30, at most an hour.")
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Strain

    @ViewBuilder private var strainSections: some View {
        if let s = scores.strain {
            if s.zones.reduce(0, +) > 0 {
                Section {
                    ZonesChart(zones: s.zones)
                } header: {
                    Text("Heart-rate zones")
                } footer: {
                    if let rest = s.restHr, let top = s.maxHr {
                        Text("Minutes in each share of your heart-rate reserve, from \(rest) bpm at rest to \(top) bpm at most.")
                    }
                }
                .listRowBackground(Theme.row)
            }
            if !s.workouts.isEmpty {
                Section("Workouts") {
                    ForEach(s.workouts) { w in
                        let reading = day?.workouts?.first { $0.id == w.id }
                            ?? HealthDayReading.Workout(id: w.id, type: w.type, minutes: w.minutes, start: nil, kcal: nil)
                        WorkoutRow(date: scores.date, workout: reading, strain: w.strain)
                    }
                }
                .listRowBackground(Theme.row)
            }
        }
        if let load = scores.load {
            Section {
                LoadCard(load: load)
            } header: {
                Text("Cardio load")
            } footer: {
                Text("The last 7 days' average against the last 28's. Building is where fitness grows; well over it, rest catches up with you.")
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Trend

    private var points: [(Date, Int)] {
        (history ?? []).reversed().compactMap { d in
            guard let date = Wire.day(d.date), let v = kind.score(d) else { return nil }
            return (date, v)
        }
    }

    private var picked: (Date, Int)? {
        guard let selected else { return nil }
        return points.min { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }
    }

    @ViewBuilder private var trend: some View {
        if history == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        } else if points.isEmpty {
            Text("No days with a score yet.").foregroundStyle(.secondary)
        } else {
            let avg = points.map(\.1).reduce(0, +) / points.count
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked.map { $0.0.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased() } ?? "AVERAGE")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(picked?.1 ?? avg)%").font(.title.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                Chart {
                    ForEach(points, id: \.0) { date, v in
                        BarMark(x: .value("Day", date, unit: .day), y: .value(kind.name, v), width: .ratio(0.6))
                            .foregroundStyle(kind.colors(v)[1].opacity(picked == nil || picked?.0 == date ? 0.9 : 0.3))
                            .cornerRadius(3)
                    }
                    if picked == nil {
                        RuleMark(y: .value("Average", avg))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 170)
            }
            .padding(.vertical, 6)
            .sensoryFeedback(.selection, trigger: picked?.0)
        }
    }
}

/// One part of a score: its value, how it did alone, and its share.
private struct PartRow: View {
    let part: HealthScores.Part
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.label).font(.subheadline.weight(.medium))
                Text("\(part.weight)%").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    if let s = part.score {
                        Capsule().fill(color).frame(width: max(6, geo.size.width * Double(s) / 100))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(part.score.map { "\($0) of 100" } ?? "no data")
    }

    /// "6h40 of 7h48", "61.5 ms · usual 55", "No data".
    private var value: String {
        if let text = part.text { return text }
        guard let v = part.value else { return "No data" }
        let unit = part.unit.map { $0 == "%" ? "%" : " \($0)" } ?? ""
        let fmt = { (x: Double) in x.rounded() == x ? String(Int(x)) : x.formatted(.number.precision(.fractionLength(1))) }
        var out = fmt(v) + unit
        if let u = part.usual { out += " · usual \(fmt(u))" }
        return out
    }
}

/// Minutes per heart-rate zone, as bars.
private struct ZonesChart: View {
    let zones: [Int]
    private static let names = ["50–60%", "60–70%", "70–80%", "80–90%", "90–100%"]

    var body: some View {
        Chart {
            ForEach(Array(zones.prefix(5).enumerated()), id: \.offset) { i, minutes in
                BarMark(x: .value("Minutes", minutes), y: .value("Zone", "Z\(i + 1) · \(Self.names[i])"))
                    .foregroundStyle(ScoreColors.strain[1].opacity(0.35 + 0.13 * Double(i)))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(minutes) min").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
            }
        }
        .chartXAxis(.hidden)
        .frame(height: 150)
        .padding(.vertical, 6)
    }
}

/// The last week's load against the last four, as a word and a position on a scale.
private struct LoadCard: View {
    let load: HealthScores.Load

    private var look: (word: String, color: Color) {
        switch load.label {
        case "detraining": ("Detraining", .blue)
        case "maintaining": ("Maintaining", .secondary)
        case "building": ("Building", .green)
        default: ("Overreaching", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(look.word).font(.title3.weight(.semibold)).foregroundStyle(look.color)
                Spacer()
                Text("\(load.ratio.formatted(.number.precision(.fractionLength(2))))×")
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                // 0.5× to 1.6×, the four bands at 0.8, 1.0 and 1.3
                let x = { (r: Double) in w * (min(1.6, max(0.5, r)) - 0.5) / 1.1 }
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        Color.blue.opacity(0.35).frame(width: x(0.8) - 1)
                        Color.secondary.opacity(0.3).frame(width: x(1.0) - x(0.8) - 2)
                        Color.green.opacity(0.45).frame(width: x(1.3) - x(1.0) - 2)
                        Color.orange.opacity(0.45)
                    }
                    .clipShape(Capsule())
                    Circle().fill(Color.primary).overlay(Circle().stroke(Theme.row, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .offset(x: x(load.ratio) - 7)
                }
            }
            .frame(height: 14)
            HStack {
                Text("Last 7 days \(Int(load.acute.rounded()))")
                Spacer()
                Text("Last 28 days \(Int(load.chronic.rounded()))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
