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
            "Last night's heart rate variability, its 7-day trend, resting heart rate, sleep score and training load, each against your own usual over the 60 days before (the trend after Plews and Buchheit: a week says more than one morning). A usual night lands around 60. Breathing rate or wrist temperature well above usual holds it at 50. Not medical advice."
        case .sleep:
            "Hours asleep against what you needed (learnt from your own nights), deep and REM sleep, time asleep in bed, and how close bedtime and waking were to your usual."
        }
    }
}

/// "7h53"
private func hm(_ minutes: Int) -> String { "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }

/// "+9 min", "+1h05"
private func plus(_ minutes: Int) -> String { minutes < 60 ? "+\(minutes) min" : "+" + hm(minutes) }

/// A score in a gradient ring with a soft glow of its colour, and the strain target as a faint arc on the track.
struct ScoreDial: View {
    let kind: ScoreKind
    let score: Int?
    var band: [Int]? = nil
    var size: CGFloat = 88

    @Environment(\.colorScheme) private var scheme

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
                    .shadow(color: colors[1].opacity(scheme == .dark ? 0.5 : 0.3), radius: size * 0.06)
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

/// On top of Health: Recovery large between Strain and Sleep, each opening its page, and below the card Coach's line
/// of the day as a message from Coach (tap: Coach's chat).
struct ScoresCard: View {
    let scores: HealthScores?
    let coach: Agent
    let open: (ScoreKind) -> Void
    let ask: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            rings
                .padding(.vertical, 8)
                .card()
            if let line = scores?.line {
                Button(action: ask) {
                    HStack(alignment: .bottom, spacing: 8) {
                        AgentMark(agent: coach, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(coach.name).font(.caption.weight(.semibold)).foregroundStyle(coach.tint)
                            Text(line).font(.subheadline).multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(coach.tint.opacity(0.14),
                                    in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6,
                                                               bottomTrailingRadius: 18, topTrailingRadius: 18,
                                                               style: .continuous))
                        Spacer(minLength: 24)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPress())
                .accessibilityHint("Opens your chat with \(coach.name)")
            }
        }
    }

    private var rings: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(ScoreKind.allCases) { kind in
                let big = kind == .recovery
                Button { open(kind) } label: {
                    VStack(spacing: 8) {
                        ScoreDial(kind: kind, score: kind.score(scores),
                                  band: kind == .strain ? scores?.strain?.target : nil,
                                  size: big ? 128 : 76)
                        VStack(spacing: 1) {
                            Text(kind.name).font(big ? .headline : .subheadline.weight(.semibold))
                            Text(kind.caption(scores)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPress())
                .layoutPriority(big ? 1 : 0)
                .accessibilityHint("Shows what it's made of")
            }
        }
        .padding(.top, 6)
        #if os(macOS)
        .frame(maxWidth: 540) // the three together in the middle, not at the window's two edges
        .frame(maxWidth: .infinity)
        #endif
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
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.short).font(.subheadline.weight(.medium))
                Text(compare).font(.caption).foregroundStyle(tone).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let v = vital.value {
                Text(metric.format(v * scale)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            RangeGauge(value: vital.value, low: vital.low, high: vital.high, color: tone == .secondary ? .primary : tone)
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

/// The value on a wide gauge: the usual range in the middle third with its ends written under it, the 30-day average
/// as a tick, the value's dot (orange only when it's off on the bad side).
struct WideGauge: View {
    let value: Double?
    let low: Double?
    let high: Double?
    var average: Double? = nil
    let color: Color
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if low != nil {
                        Capsule().fill(Color.primary.opacity(0.14)).frame(width: w / 3).offset(x: w / 3)
                    }
                    if let a = average.flatMap(position) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary)
                            .frame(width: 2, height: h + 8).offset(x: a * w - 1)
                    }
                    if let x = value.flatMap(position) {
                        Circle().fill(color)
                            .overlay(Circle().stroke(Theme.row, lineWidth: 3))
                            .frame(width: h + 8, height: h + 8)
                            .offset(x: x * w - (h + 8) / 2)
                    }
                }
            }
            .frame(height: 12)
            if let low, let high {
                GeometryReader { geo in
                    let w = geo.size.width
                    Text(format(low)).position(x: w / 3, y: 7)
                    Text(format(high)).position(x: 2 * w / 3, y: 7)
                }
                .frame(height: 14)
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityHidden(true)
    }

    /// As `RangeGauge`: the range is 1/3…2/3, a range's width either side fills the rest.
    private func position(_ v: Double) -> Double {
        guard let low, let high, high > low else { return 0.5 }
        return min(0.97, max(0.03, (v - low) / (high - low) / 3 + 1.0 / 3))
    }
}

// MARK: - The day's heart rate

/// Hourly heart rate over the day in grey: sleep shaded in sleep's purple (last night from midnight, naps, and tonight
/// from the next day's bedtime), workouts in orange.
struct DayHeartChart: View {
    let day: HealthDayReading
    /// The next date's reading: its night may start this evening.
    var next: HealthDayReading? = nil

    private var start: Date? { Wire.day(day.date) }

    private var points: [(Date, Int)] {
        guard let start, let hourly = day.hrHourly else { return [] }
        return hourly.enumerated().compactMap { h, bpm in
            bpm.map { (start.addingTimeInterval(Double(h) * 3600 + 1800), $0) }
        }
    }

    /// Asleep in the day: last night's end clipped to midnight, each nap, tonight's start up to midnight.
    static func sleepSpans(day: HealthDayReading, next: HealthDayReading?) -> [(Date, Date)] {
        guard let midnight = Wire.day(day.date) else { return [] }
        let end = midnight.addingTimeInterval(86_400)
        var spans: [(Date, Date)] = []
        if let night = day.sleep, let wake = night.wakeDate, wake > midnight {
            spans.append((max(night.bedtimeDate ?? midnight, midnight), min(wake, end)))
        }
        for nap in day.naps ?? [] {
            if let s = Wire.parse(nap.start), let e = Wire.parse(nap.end), e > s { spans.append((s, e)) }
        }
        if let bed = next?.sleep?.bedtimeDate, bed >= midnight, bed < end { spans.append((bed, end)) }
        return spans
    }

    static func workoutSpans(_ day: HealthDayReading) -> [(Date, Date)] {
        (day.workouts ?? []).compactMap { w in
            guard let s = w.start.flatMap(Wire.parse) else { return nil }
            let e = w.end.flatMap(Wire.parse) ?? s.addingTimeInterval(Double((w.minutes ?? 30) * 60))
            return (s, e)
        }
    }

    /// The hourly points whose hour overlaps each workout.
    private func during(_ workouts: [(Date, Date)]) -> [[(Date, Int)]] {
        workouts.map { w in
            points.filter { p in p.0.addingTimeInterval(1800) > w.0 && p.0.addingTimeInterval(-1800) < w.1 }
        }
        .filter { !$0.isEmpty }
    }

    private var header: String? {
        switch (day.restingHr, day.maxHr) {
        case let (r?, m?): "Resting \(r) · up to \(m) bpm"
        case let (r?, nil): "Resting \(r) bpm"
        case let (nil, m?): "Up to \(m) bpm"
        default: nil
        }
    }

    var body: some View {
        let sleeps = Self.sleepSpans(day: day, next: next)
        let workouts = Self.workoutSpans(day)
        let orange = ScoreColors.strain[1]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let header {
                    Text(header).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                HStack(spacing: 12) {
                    if !sleeps.isEmpty { legend(ScoreColors.sleep[1], "Asleep") }
                    if !workouts.isEmpty { legend(orange, "Workout") }
                }
            }
            Chart {
                ForEach(Array(sleeps.enumerated()), id: \.offset) { _, s in
                    RectangleMark(xStart: .value("From", s.0), xEnd: .value("To", s.1))
                        .foregroundStyle(ScoreColors.sleep[1].opacity(0.14))
                }
                ForEach(Array(workouts.enumerated()), id: \.offset) { _, w in
                    RectangleMark(xStart: .value("From", w.0), xEnd: .value("To", w.1))
                        .foregroundStyle(orange.opacity(0.18))
                }
                ForEach(points, id: \.0) { time, bpm in
                    AreaMark(x: .value("Time", time), y: .value("bpm", bpm))
                        .foregroundStyle(LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", time), y: .value("bpm", bpm), series: .value("Line", "day"))
                        .foregroundStyle(Color.secondary)
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(during(workouts).enumerated()), id: \.offset) { i, run in
                    ForEach(run, id: \.0) { time, bpm in
                        LineMark(x: .value("Time", time), y: .value("bpm", bpm), series: .value("Line", "workout \(i)"))
                            .foregroundStyle(orange)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.monotone)
                        if run.count == 1 { // a short workout has one hour: a dot, as a line needs two
                            PointMark(x: .value("Time", time), y: .value("bpm", bpm)).foregroundStyle(orange).symbolSize(30)
                        }
                    }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate through the day" + (day.maxHr.map { ", up to \($0) beats a minute" } ?? ""))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - A score's page

/// One score: the ring on a glow of its colour with the week under it, what it's made of, and the trend.
struct ScoreDetailView: View {
    let kind: ScoreKind
    /// The day as Apple Health has it (the night, workouts); nil when not loaded.
    let day: HealthDayReading?
    let date: Date

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    /// What the Health page had, then the day's own, fetched again on open.
    @State private var scores: HealthScores
    @State private var history: [ScoreDay]?
    /// Coach's take, once asked for.
    @State private var insight: String?
    @State private var asking = false
    @State private var insightError: String?
    @State private var selected: Date?
    @State private var range = 30

    init(kind: ScoreKind, scores: HealthScores, day: HealthDayReading?, date: Date) {
        self.kind = kind
        self.day = day
        self.date = date
        _scores = State(initialValue: scores)
    }

    private var tint: Color { kind.colors(kind.score(scores))[1] }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                coachCard
                switch kind {
                case .recovery: recoverySections
                case .sleep: sleepSections
                case .strain: strainSections
                }
                DetailCard("Trend", note: kind.about) { trend }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .previewAnchor()
        .pageGlow(tint)
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let fresh = try? env.api.healthScores(date: date)
            history = (try? await env.api.healthScoreHistory(days: 30, to: date)) ?? []
            if let fresh = await fresh { scores = fresh }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            ScoreDial(kind: kind, score: kind.score(scores),
                      band: kind == .strain ? scores.strain?.target : nil, size: 184)
            VStack(spacing: 6) {
                Text(headline).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                if let sub = subline {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            if week.contains(where: { $0.score != nil }) {
                ScoreWeek(kind: kind, days: week)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// The 7 days up to the page's, nil where there's no score.
    private var week: [(date: Date, score: Int?)] {
        guard let history else { return [] }
        let cal = Calendar.current
        var byDay: [String: Int] = [:]
        for d in history { if let v = kind.score(d) { byDay[d.date] = v } }
        let last = cal.startOfDay(for: date)
        return (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: last) else { return nil }
            return (d, byDay[Wire.dayString(d)])
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

    // MARK: Coach's take

    private var coach: Agent { chat.agent("coach") }

    /// Asked for with a tap (one model call), then the way into Coach's chat to talk it over.
    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let insight {
                HStack(alignment: .top, spacing: 12) {
                    AgentMark(agent: coach, size: 28)
                    Text(insight).font(.callout).textSelection(.enabled)
                }
                .transition(.opacity)
                Button { push.route = .agent(coach.id) } label: {
                    Label("Talk it over with \(coach.name)", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(Theme.accent)
            } else if asking {
                HStack(spacing: 12) {
                    LivePebble(mood: "thinking", size: 28, figure: coach.figure)
                        .foregroundStyle(coach.tint)
                        .allowsHitTesting(false)
                    Text("\(coach.name) is looking at your numbers…").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                Button { Task { await askCoach() } } label: {
                    HStack(spacing: 12) {
                        AgentMark(agent: coach, size: 28)
                        Text("What does \(coach.name) make of it?").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPress())
                if let insightError {
                    Label(insightError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.easeInOut(duration: 0.25), value: asking)
    }

    private func askCoach() async {
        asking = true
        insightError = nil
        defer { asking = false }
        do {
            let got = try await env.api.healthInsight(kind: kind.rawValue, date: date)
            withAnimation { insight = got.text }
        } catch {
            insightError = error.localizedDescription
        }
    }

    /// Parts one under the other, a hairline between.
    private func parts(_ parts: [HealthScores.Part]) -> some View {
        ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
            if i > 0 { Divider().padding(.vertical, 12) }
            PartRow(part: part, kind: kind, tint: tint)
        }
    }

    // MARK: Recovery

    @ViewBuilder private var recoverySections: some View {
        if let r = scores.recovery {
            if !r.flags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(r.flags, id: \.self) { flag in
                        Label(flag == "wrist_temp" ? "Wrist temperature above your usual" : "Breathing rate above your usual",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("Either can mean your body is fighting something, so recovery is held at 50% at most.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .foregroundStyle(.orange)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if !r.contributors.isEmpty {
                DetailCard("Contributors", note: "Each part is scored against your own last 60 days: a usual morning lands around 60, better than usual higher, worse lower. Higher HRV is better, a lower heart rate asleep is better, and a training load well over your usual costs a little.") {
                    parts(r.contributors)
                }
            }
        }
    }

    // MARK: Sleep

    @ViewBuilder private var sleepSections: some View {
        if let night = day?.sleep {
            DetailCard("Last night", note: night.deepMin != nil ? "The marks are the usual range for adults; your own usual is under Deep and REM in Contributors." : nil) {
                SleepStages(night: night)
            }
        }
        if let s = scores.sleep {
            DetailCard("Contributors", note: "Hours against what you needed count for half: 90% of the need scores 75, 80% scores 50. Deep and REM are scored on their share of the night.") {
                parts(s.contributors)
            }
            DetailCard("Sleep need", note: s.need != nil ? "Your usual need is learnt from up to 90 of your nights, leaving out the shortest and longest tenth. A hard day adds a little, and half of what the last three nights were short adds the rest, at most 45 min." : nil) {
                VStack(spacing: 12) {
                    if let n = s.need {
                        NeedLine(label: "Your usual need", value: hm(n.base), icon: "bed.double.fill")
                        if n.strain > 0 { NeedLine(label: "After the day before's strain", value: plus(n.strain), icon: "flame.fill") }
                        if n.debt > 0 { NeedLine(label: "Catching up on recent nights", value: plus(n.debt), icon: "arrow.uturn.backward") }
                        Divider()
                    }
                    NeedLine(label: "Needed last night", value: hm(s.needMin), icon: "moon.stars.fill", bold: true)
                    NeedLine(label: "Short, last 3 nights", value: s.debtMin > 0 ? hm(s.debtMin) : "Nothing", icon: "hourglass")
                }
            }
        }
    }

    // MARK: Strain

    @ViewBuilder private var strainSections: some View {
        if let s = scores.strain {
            if s.zones.reduce(0, +) > 0 {
                DetailCard("Heart-rate zones", note: s.restHr.flatMap { rest in s.maxHr.map { top in
                    "Zones of your heart-rate reserve, from \(rest) bpm at rest (your 30-day usual) to \(top) bpm at most (the middle of your three highest workout peaks, so one strap glitch doesn't count). Zone 1 starts at half the reserve, each next one 10% higher. The Workout app on the Watch may set its zones a little differently."
                } }) {
                    ZonesChart(zones: s.zones, bpm: s.zoneBpm)
                }
            }
            if !s.workouts.isEmpty {
                DetailCard("Workouts") {
                    ForEach(Array(s.workouts.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Divider().padding(.vertical, 10) }
                        let reading = day?.workouts?.first { $0.id == w.id }
                            ?? HealthDayReading.Workout(id: w.id, type: w.type, minutes: w.minutes, start: nil, kcal: nil)
                        WorkoutRow(date: scores.date, workout: reading, strain: w.strain)
                    }
                }
            }
        }
        if let load = scores.load {
            DetailCard("Cardio load", note: load.why ?? "The last 7 days' average against the last 28's. Building is where fitness grows; well over it, rest catches up with you.") {
                LoadCard(load: load, date: Wire.day(scores.date) ?? .now)
            }
        }
    }

    // MARK: Trend

    private var points: [(Date, Int)] {
        (history ?? []).reversed().suffix(range).compactMap { d in
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
        } else if points.isEmpty && range == 30 {
            Text("No days with a score yet.").foregroundStyle(.secondary)
        } else {
            let avg = points.isEmpty ? 0 : points.map(\.1).reduce(0, +) / points.count
            VStack(alignment: .leading, spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked.map { $0.0.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased() } ?? "AVERAGE")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(picked?.1 ?? avg)%").font(.largeTitle.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .animation(.snappy, value: picked?.0)
                Chart {
                    ForEach(points, id: \.0) { date, v in
                        BarMark(x: .value("Day", date, unit: .day), y: .value(kind.name, v), width: .ratio(0.62))
                            .foregroundStyle(kind.colors(v)[1].gradient.opacity(picked == nil || picked?.0 == date ? 1 : 0.3))
                            .cornerRadius(4)
                    }
                    if picked == nil, !points.isEmpty {
                        RuleMark(y: .value("Average", avg))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    if range == 7 {
                        AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 180)
                .animation(.snappy, value: range)
            }
            .sensoryFeedback(.selection, trigger: picked?.0)
        }
    }
}

/// The week under the ring: a bar a day, the page's day in full colour with its number.
private struct ScoreWeek: View {
    let kind: ScoreKind
    let days: [(date: Date, score: Int?)]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                let last = i == days.count - 1
                VStack(spacing: 5) {
                    Text(d.score.map(String.init) ?? "–")
                        .font(.caption2.weight(last ? .bold : .medium)).monospacedDigit()
                        .foregroundStyle(last ? Color.primary : Color.secondary)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(d.score.map { kind.colors($0)[1].opacity(last ? 1 : 0.4) } ?? Color.primary.opacity(0.08))
                        .frame(width: 22, height: max(6, 54 * Double(d.score ?? 0) / 100))
                    Text(d.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(last ? .bold : .regular))
                        .foregroundStyle(last ? Color.primary : Color.secondary)
                }
                .frame(height: 92, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days: " + days.compactMap { $0.score.map(String.init) }.joined(separator: ", "))
    }
}

/// A part's score in a word, as Oura says it; only the last one warns.
private func standing(_ score: Int?) -> (word: String, warns: Bool) {
    guard let score else { return ("No data", false) }
    if score >= 80 { return ("Optimal", false) }
    if score >= 60 { return ("Good", false) }
    if score >= 40 { return ("Fair", false) }
    return ("Pay attention", true)
}

/// One part of a score: its name and share, how it stands in a word, the value, a bar, and your usual.
private struct PartRow: View {
    let part: HealthScores.Part
    let kind: ScoreKind
    let tint: Color

    var body: some View {
        let stand = standing(part.score)
        // One hue a page: the score's own, orange only for a part that needs attention.
        let color = stand.warns ? Color.orange : tint
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.label).font(.subheadline.weight(.semibold))
                    Text("\(part.weight)% of score").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(stand.word).font(.caption.weight(.semibold))
                    .foregroundStyle(stand.warns ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((stand.warns ? Color.orange : Color.primary).opacity(stand.warns ? 0.14 : 0.07), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                if let usual { usual }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    if let s = part.score {
                        Capsule().fill(color.gradient).frame(width: max(6, geo.size.width * Double(s) / 100))
                    }
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(part.score.map { "\($0) of 100, \(stand.word)" } ?? "no data")
    }

    private var icon: String {
        switch part.key {
        case "hrv": "waveform.path.ecg"
        case "hrv_week": "chart.line.uptrend.xyaxis"
        case "sleep_hr", "resting_hr": "heart.fill"
        case "sleep": "moon.fill"
        case "load": "figure.run"
        case "duration": "clock.fill"
        case "deep": "moon.zzz.fill"
        case "rem": "brain.head.profile"
        case "efficiency": "bed.double.fill"
        case "consistency": "calendar.badge.clock"
        default: kind.icon
        }
    }

    private func hm(_ minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" : "\(minutes) min" }

    private func fmt(_ x: Double) -> String {
        x.rounded() == x ? String(Int(x)) : x.formatted(.number.precision(.fractionLength(1)))
    }

    /// "6h40 of 7h48", "61.5 ms", "No data".
    private var value: String {
        if let text = part.text { return text }
        guard let v = part.value else { return "No data" }
        return fmt(v) + (part.unit.map { $0 == "%" || $0 == "×" ? $0 : " \($0)" } ?? "")
    }

    /// Under the usual: "usual 55 ↑" for numbers, "usual 7h12 · −0h32" for the night's timed parts.
    private var usual: AnyView? {
        if let u = part.usualText {
            var line = Text("usual \(u)")
            if let diff = part.diffMin {
                line = line + Text(abs(diff) < 5 ? " · as usual" : " · \(diff > 0 ? "+" : "−")\(hm(abs(diff)))")
                    .foregroundColor(abs(diff) < 5 ? .secondary : diff > 0 ? .green : .orange)
            }
            return AnyView(line.font(.caption).foregroundStyle(.secondary).monospacedDigit())
        }
        guard let u = part.usual, let v = part.value else { return nil }
        let arrow = v > u ? "arrow.up" : v < u ? "arrow.down" : "equal"
        return AnyView(HStack(spacing: 3) {
            Image(systemName: arrow).font(.caption2.weight(.bold))
            Text("usual \(fmt(u))")
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit())
    }
}

/// A line of the sleep need: an icon, what it is, how much.
private struct NeedLine: View {
    let label: String
    let value: String
    let icon: String
    var bold = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundStyle(ScoreColors.sleep[1]).frame(width: 22)
            Text(label).font(.subheadline.weight(bold ? .semibold : .regular))
            Spacer()
            Text(value).font(.subheadline.weight(bold ? .bold : .medium)).monospacedDigit()
        }
    }
}

/// Last night's stages: the night as one bar, then each stage with its share against the usual range for adults.
private struct SleepStages: View {
    let night: SleepNight

    private struct Stage { let name: String; let minutes: Int; let color: Color; let range: ClosedRange<Double> }

    private var stages: [Stage] {
        guard let deep = night.deepMin, let core = night.coreMin, let rem = night.remMin else { return [] }
        return [
            Stage(name: "Awake", minutes: night.awakeMin ?? 0, color: Color(uiColor: UIColor(hex: 0xDCDBFF)), range: 0...0.10),
            Stage(name: "REM", minutes: rem, color: Color(uiColor: UIColor(hex: 0xA6A4FF)), range: 0.18...0.25),
            Stage(name: "Core", minutes: core, color: Color(uiColor: UIColor(hex: 0x7A78F5)), range: 0.45...0.60),
            Stage(name: "Deep", minutes: deep, color: Color(uiColor: UIColor(hex: 0x4A47C9)), range: 0.13...0.23),
        ]
    }

    var body: some View {
        let total = Double(max(1, stages.reduce(0) { $0 + $1.minutes }))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(SleepCard.duration(night.asleepMin)) asleep").font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if let bed = night.bedtimeDate, let wake = night.wakeDate {
                    Label("\(bed.formatted(date: .omitted, time: .shortened)) – \(wake.formatted(date: .omitted, time: .shortened))",
                          systemImage: "bed.double")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if stages.isEmpty {
                Text("Stages come from the Watch when you sleep with it on.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(stages.filter { $0.minutes > 0 }, id: \.name) { s in
                            s.color.frame(width: max(2, (geo.size.width - 6) * Double(s.minutes) / total))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 14)
                VStack(spacing: 14) {
                    ForEach(stages, id: \.name) { s in
                        let share = Double(s.minutes) / total
                        VStack(spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Circle().fill(s.color).frame(width: 8, height: 8)
                                Text(s.name).font(.subheadline.weight(.semibold))
                                Text("\(Int((share * 100).rounded()))%").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(s.range.contains(share) ? s.color : .orange).monospacedDigit()
                                Spacer()
                                Text(SleepCard.duration(s.minutes)).font(.subheadline).monospacedDigit()
                            }
                            GeometryReader { geo in
                                let w = geo.size.width
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.primary.opacity(0.14))
                                        .frame(width: w * (s.range.upperBound - s.range.lowerBound), height: 12)
                                        .offset(x: w * s.range.lowerBound)
                                    Capsule().fill(s.color).frame(width: max(4, w * share))
                                }
                            }
                            .frame(height: 8)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// Minutes per heart-rate zone: the most-used one in words, then a coloured bar per zone with its bpm.
struct ZonesChart: View {
    let zones: [Int]
    /// Where zones 1–5 start, then the max.
    var bpm: [Int]? = nil
    private static let names = ["50–60%", "60–70%", "70–80%", "80–90%", "90–100%"]
    static let colors: [Color] = [0xFFE2BF, 0xFFC98A, 0xFFAA55, 0xFF8530, 0xFF5A1F].map { Color(uiColor: UIColor(hex: $0)) }

    static func name(_ i: Int, bpm: [Int]?) -> String {
        if let bpm, bpm.count == 6 { return "Z\(i + 1) · \(bpm[i])–\(bpm[i + 1])" }
        return "Z\(i + 1) · \(names[i])"
    }

    private func range(_ i: Int) -> String {
        if let bpm, bpm.count == 6 { return "\(bpm[i])–\(bpm[i + 1]) bpm" }
        return Self.names[i]
    }

    var body: some View {
        let shown = Array(zones.prefix(5))
        let top = max(1, shown.max() ?? 1)
        let most = shown.firstIndex(of: shown.max() ?? 0) ?? 0
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shown.reduce(0, +)) min in the zones").font(.title3.weight(.semibold)).monospacedDigit()
                Text("Most in zone \(most + 1)").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { i, minutes in
                HStack(spacing: 10) {
                    Text("Z\(i + 1)")
                        .font(.caption.weight(.heavy)).foregroundStyle(.black.opacity(0.75))
                        .frame(width: 30, height: 22)
                        .background(Self.colors[i], in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(range(i)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            Text("\(minutes) min").font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(minutes == 0 ? .secondary : .primary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                if minutes > 0 {
                                    Capsule().fill(Self.colors[i].gradient).frame(width: max(6, geo.size.width * Double(minutes) / Double(top)))
                                }
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Zone \(i + 1), \(range(i)), \(minutes) minutes")
            }
        }
    }
}

/// The last week's load against the last four, as a word and a position on a scale.
private struct LoadCard: View {
    let load: HealthScores.Load
    /// The day the page is for: the bars are the 7 before it.
    var date: Date = .now

    private var look: (word: String, color: Color) {
        switch load.label {
        case "detraining": ("Detraining", .secondary)
        case "maintaining": ("Maintaining", .secondary)
        case "building": ("Building", ScoreColors.strain[1])
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
                        // Strain's orange, stronger as the load grows.
                        let o = ScoreColors.strain[1]
                        o.opacity(0.15).frame(width: x(0.8) - 1)
                        o.opacity(0.3).frame(width: x(1.0) - x(0.8) - 2)
                        o.opacity(0.55).frame(width: x(1.3) - x(1.0) - 2)
                        o.opacity(0.85)
                    }
                    .clipShape(Capsule())
                    Circle().fill(Color.primary).overlay(Circle().stroke(Theme.row, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .offset(x: x(load.ratio) - 7)
                }
            }
            .frame(height: 14)
            HStack {
                Text(load.acuteStrain.map { "Last 7 days \($0)% a day" } ?? "Last 7 days \(Int(load.acute.rounded()))")
                Spacer()
                Text(load.chronicStrain.map { "4 weeks \($0)% a day" } ?? "Last 28 days \(Int(load.chronic.rounded()))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let days = load.days, days.count == 7 {
                LoadWeek(days: days, usual: load.chronicStrain, date: date)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 7 days before, each day's strain as a bar, with the 4-week average as a line.
private struct LoadWeek: View {
    let days: [Int?]
    let usual: Int?
    let date: Date

    var body: some View {
        Chart {
            ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                // Categories, not numbers: on a numeric axis a ratio width has no band and the bars vanish.
                BarMark(x: .value("Day", String(i)), y: .value("Strain", v ?? 0), width: .ratio(0.6))
                    .foregroundStyle(ScoreColors.strain[1].opacity(v == nil ? 0.15 : 0.8))
                    .cornerRadius(3)
            }
            if let usual {
                RuleMark(y: .value("Usual", usual))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: (0..<7).map(String.init)) { value in
                AxisValueLabel {
                    if let i = value.as(String.self).flatMap(Int.init) { Text(label(i)) }
                }
            }
        }
        .frame(height: 90)
    }

    /// The weekday of each bar: the last is the day before `date`.
    private func label(_ i: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: i - 7, to: date) ?? date
        return day.formatted(.dateTime.weekday(.narrow))
    }
}
