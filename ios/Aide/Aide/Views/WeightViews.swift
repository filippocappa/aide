import Charts
import SwiftUI

// Weight (docs/API.md, "Apple Health", Weight): Apple Health's readings and the ones logged through Aide, the 7-day
// average and the trend against the pace the food goal wants. A card on Health → Body, a page with the chart and the
// days, a row on the targets page, and "Log weight", which the phone also writes to Health.

extension WeightSummary {
    /// Neutral: Health keeps to sleep's and strain's colours.
    static let color = Theme.accent

    /// "66.0 kg".
    static func kg(_ v: Double) -> String { "\(v.formatted(.number.precision(.fractionLength(1)))) kg" }

    /// "+0.10 kg", "−0.25 kg".
    static func signed(_ v: Double, digits: Int = 2) -> String {
        (v < 0 ? "−" : "+") + "\(abs(v).formatted(.number.precision(.fractionLength(digits)))) kg"
    }

    /// The number to show: the 7-day average, else the latest reading.
    var shown: Double? { averageKg ?? latest?.kg }

    /// What `shown` is: "7-day average", or "31 Aug" for a lone reading.
    var shownLabel: String? {
        if averageKg != nil { return "7-day average" }
        return latest.map { HealthDayName.of($0.date) }
    }

    /// "−0.10 kg a week".
    var rateText: String? { rateKgWeek.map { Self.signed($0) + " a week" } }

    /// The trend against the goal, in a few words.
    var verdictText: String? {
        switch (goal, verdict) {
        case (_, "on_track"): "On track"
        case ("gain", "below"): "Below the pace to gain"
        case ("gain", "above"): "Gaining faster than planned"
        case ("lose", "below"): "Losing faster than planned"
        case ("lose", "above"): "Not losing as planned"
        case (_, "below"): "Going down"
        case (_, "above"): "Going up"
        default: nil
        }
    }

    var isOff: Bool { verdict == "below" || verdict == "above" }

    /// "+0.04 to +0.08 kg a week".
    var paceText: String? {
        paceKgWeek.map { "\(Self.signed($0.lowKg)) to \(Self.signed($0.highKg)) a week" }
    }

    /// One line under the number: the trend and the verdict, or why there's none yet.
    var trendLine: String {
        if let rateText {
            return [rateText, verdictText].compactMap { $0 }.joined(separator: " · ")
        }
        if let days = daysSince, days > 7 { return "Last weighed \(days) days ago" }
        return "A trend after a few weigh-ins over two weeks"
    }
}

/// The changes of the 7-day average, worked out on the phone from the readings with the server's rules
/// (`weight.py`), so the 28-day rate is the summary's `rateKgWeek`.
enum WeightMath {
    struct Change: Equatable {
        let days: Int
        /// The 7-day average against the one `days` before.
        let kg: Double?
        /// From a straight line through the readings of the last `days` days.
        let rateKgWeek: Double?
    }

    /// Whole days from `today` back to a reading's date (negative before).
    private static func offset(_ date: String, _ today: Date, _ calendar: Calendar) -> Int? {
        Wire.day(date).flatMap { calendar.dateComponents([.day], from: today, to: $0).day }
    }

    /// The mean of the readings in the 7 days up to `end` days from today (0 today, -14 two weeks ago).
    static func average(_ readings: [WeightReading], endingAt end: Int, today: Date,
                        calendar: Calendar = .current) -> Double? {
        let kgs = readings.filter { r in offset(r.date, today, calendar).map { $0 > end - 7 && $0 <= end } ?? false }
            .map(\.kg)
        return kgs.isEmpty ? nil : kgs.reduce(0, +) / Double(kgs.count)
    }

    /// The slope a week of a least-squares line through the readings after `today − days`: at least 3, spread over
    /// half the window or more; rounded to 2 decimals as the server does.
    static func rate(_ readings: [WeightReading], days: Int, today: Date, calendar: Calendar = .current) -> Double? {
        let points = readings.compactMap { r in offset(r.date, today, calendar).flatMap { $0 > -days && $0 <= 0 ? (Double($0), r.kg) : nil } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 3, let first = points.first, let last = points.last,
              last.0 - first.0 >= Double(days / 2) else { return nil }
        let mx = points.map(\.0).reduce(0, +) / Double(points.count)
        let my = points.map(\.1).reduce(0, +) / Double(points.count)
        let den = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        guard den > 0 else { return nil }
        let slope = points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / den
        return (slope * 7 * 100).rounded() / 100
    }

    static func change(_ readings: [WeightReading], days: Int, today: Date = Calendar.current.startOfDay(for: .now),
                       calendar: Calendar = .current) -> Change {
        let now = average(readings, endingAt: 0, today: today, calendar: calendar)
        let then = average(readings, endingAt: -days, today: today, calendar: calendar)
        return Change(days: days, kg: now.flatMap { n in then.map { n - $0 } },
                      rateKgWeek: rate(readings, days: days, today: today, calendar: calendar))
    }

    /// A change that goes the other way from the goal (down while gaining, up while losing): the only orange.
    static func against(_ kg: Double, goal: String?) -> Bool {
        guard abs(kg) >= 0.05 else { return false }
        return (goal == "gain" && kg < 0) || (goal == "lose" && kg > 0)
    }
}

/// The weight on Health: the number, this week's and three weeks' change, the last month in small, and Log weight.
struct WeightCard: View {
    let weight: WeightList
    let open: () -> Void
    let log: () -> Void

    /// "−0.2 kg this week · −0.5 kg in 3 weeks", or the summary's line without enough readings.
    private var changes: String {
        let s = weight.summary
        let week = WeightMath.change(weight.readings, days: 7).kg
        let parts = [week.map { WeightSummary.signed($0, digits: 1) + " this week" },
                     s.changeKg.map { WeightSummary.signed($0, digits: 1) + " in 3 weeks" }].compactMap { $0 }
        return parts.isEmpty ? s.trendLine : parts.joined(separator: " · ")
    }

    var body: some View {
        let s = weight.summary
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        if let v = s.shown {
                            Text(WeightSummary.kg(v)).font(.title2.weight(.semibold)).monospacedDigit()
                        } else {
                            Text("No weight yet").font(.headline)
                        }
                        if let label = s.shownLabel {
                            Text(label).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    Text(changes).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    if let verdict = s.verdictText, s.rateKgWeek != nil {
                        Text(verdict).font(.subheadline).foregroundStyle(s.isOff ? .orange : .secondary)
                    }
                    if weight.readings.count >= 2 {
                        WeightChart(readings: Array(weight.readings.suffix(30)), small: true)
                            .frame(height: 44)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .accessibilityHint("Shows the chart")
            RowDivider(leading: 16)
            Button(action: log) {
                Label("Log weight", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
        }
    }
}

/// The readings as dots and the 7-day average as a line, oldest on the left; the goal's pace as a light band.
struct WeightChart: View {
    /// Oldest first.
    let readings: [WeightReading]
    var small = false
    var selected: Binding<Date?>? = nil
    /// Drawn from this day on; the readings before it still count in the average.
    var from: Date? = nil
    /// The goal's pace over the last 28 days: from the average then, widening to the pace's low and high today.
    var pace: (start: Date, kg: Double, end: Date, low: Double, high: Double)? = nil

    /// Each reading's day and the mean of the readings in the 7 days up to it.
    static func averages(_ readings: [WeightReading]) -> [(date: Date, kg: Double, average: Double)] {
        let dated = readings.compactMap { r in Wire.day(r.date).map { (date: $0, kg: r.kg) } }
        return dated.map { item in
            let week = dated.filter { $0.date <= item.date && item.date.timeIntervalSince($0.date) < 7 * 86_400 }
            return (item.date, item.kg, week.map(\.kg).reduce(0, +) / Double(week.count))
        }
    }

    var body: some View {
        let points = Self.averages(readings).filter { p in from.map { p.date >= $0 } ?? true }
        let kgs = points.flatMap { [$0.kg, $0.average] } + (pace.map { [$0.kg + $0.low, $0.kg + $0.high] } ?? [])
        let lo = (kgs.min() ?? 0) - 0.5, hi = (kgs.max() ?? 1) + 0.5
        let chart = Chart {
            if let pace {
                ForEach([(pace.start, pace.kg, pace.kg), (pace.end, pace.kg + pace.low, pace.kg + pace.high)], id: \.0) { d, l, h in
                    AreaMark(x: .value("Day", d), yStart: .value("Low", l), yEnd: .value("High", h),
                             series: .value("Band", "pace"))
                        .foregroundStyle(WeightSummary.color.opacity(0.1))
                }
            }
            ForEach(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Average", p.average),
                         series: .value("Line", "average"))
                    .foregroundStyle(WeightSummary.color)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", p.date, unit: .day), y: .value("Weight", p.kg))
                    .foregroundStyle(WeightSummary.color.opacity(0.45))
                    .symbolSize(small ? 10 : 28)
            }
            if let day = selected?.wrappedValue {
                RuleMark(x: .value("Day", day, unit: .day)).foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: lo...hi)
        Group {
            if small {
                chart.chartXAxis(.hidden).chartYAxis(.hidden).allowsHitTesting(false).accessibilityHidden(true)
            } else if let selected {
                chart.chartXSelection(value: selected)
            } else {
                chart
            }
        }
    }
}

/// The weight page, in the metric pages' layout: the 7-day average and the verdict on top, the changes over 7, 14
/// and 28 days, the chart over a week, a month or six months with the goal's pace, and the days (long-press one
/// logged through Aide to delete it).
struct WeightView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var health: HealthService
    /// Something was logged or deleted here.
    var changed: () async -> Void = {}

    @State private var weight: WeightList?
    @State private var error: String?
    @State private var period: MetricPeriod
    @State private var selected: Date?
    @State private var logging = false
    @State private var showAll = false

    init(changed: @escaping () async -> Void = {}) {
        self.changed = changed
        var period = MetricPeriod.month
        #if DEBUG
        if let p = MetricPeriod.preview, p != .day { period = p }
        #endif
        _period = State(initialValue: period)
    }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    private var rangeDays: Int { period == .week ? 7 : period == .half ? 182 : 30 }

    private var firstShown: Date { Calendar.current.date(byAdding: .day, value: 1 - rangeDays, to: today) ?? today }

    private var shown: [WeightReading] {
        let from = Wire.dayString(firstShown)
        return (weight?.readings ?? []).filter { $0.date >= from }
    }

    private var picked: (date: Date, kg: Double, average: Double)? {
        guard let selected, let weight else { return nil }
        return WeightChart.averages(weight.readings).filter { $0.date >= firstShown }.min {
            abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
        }
    }

    /// The pace band on the month and six months: from the average 28 days ago, the goal's rate for 4 weeks.
    private var pace: (start: Date, kg: Double, end: Date, low: Double, high: Double)? {
        guard period != .week, let weight, let p = weight.summary.paceKgWeek,
              let then = WeightMath.average(weight.readings, endingAt: -28, today: today),
              let start = Calendar.current.date(byAdding: .day, value: -28, to: today) else { return nil }
        return (start, then, today, p.lowKg * 4, p.highKg * 4)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let weight {
                    top(weight.summary)
                    changes(weight)
                    chartCard
                    dayByDay
                } else if let error {
                    TopBlock("Weight")
                    ErrorCard(text: error)
                } else {
                    TopBlock("Weight")
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .previewAnchor()
        .pageGlow(WeightSummary.color)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Log weight", systemImage: "plus") { logging = true }
            }
        }
        .weightEntry(isPresented: $logging) {
            await load()
            await changed()
        }
        .sensoryFeedback(.selection, trigger: picked?.date)
        .onChange(of: period) { selected = nil }
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: The top

    private func top(_ s: WeightSummary) -> some View {
        TopBlock("Weight", overline: s.shownLabel) {
            if let v = s.shown {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(v.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 48).bold()).monospacedDigit()
                    Text("kg").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(s.trendLine).foregroundStyle(s.isOff ? .orange : .secondary)
                if let pace = s.paceText {
                    Text("Your goal wants \(pace).").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No weight yet. Log one, or weigh in on a scale that writes to Apple Health.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Changes

    @ViewBuilder private func changes(_ weight: WeightList) -> some View {
        let rows = [7, 14, 28].map { WeightMath.change(weight.readings, days: $0, today: today) }
        if rows.contains(where: { $0.kg != nil }) {
            DetailCard("Changes", note: "The 7-day average against the one before; the rate from a straight line through the window.",
                       padding: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, c in
                    if i > 0 { RowDivider(leading: 16) }
                    changeRow(c, weight: weight)
                }
            }
        }
    }

    private func changeRow(_ c: WeightMath.Change, weight: WeightList) -> some View {
        let warn = c.kg.map { WeightMath.against($0, goal: weight.summary.goal) } ?? false
        let window = Calendar.current.date(byAdding: .day, value: -c.days, to: today)
        let readings = weight.readings.filter { r in
            guard let window, let d = Wire.day(r.date) else { return false }
            return d > window
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.days) days").font(.body.weight(.medium))
                Text(c.rateKgWeek.map { WeightSummary.signed($0) + " a week" } ?? "Not enough weigh-ins")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if readings.count >= 2 {
                WeightChart(readings: weight.readings, small: true, from: window.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) })
                    .frame(width: 64, height: 26)
            }
            HStack(spacing: 4) {
                if let kg = c.kg {
                    Image(systemName: abs(kg) < 0.05 ? "arrow.right" : kg > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(WeightSummary.signed(kg, digits: 1))
                } else {
                    Text("–")
                }
            }
            .font(.body.weight(.semibold)).monospacedDigit()
            .foregroundStyle(warn ? Color.orange : Color.primary)
            .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: The chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(MetricPeriod.allCases.filter { $0 != .day }) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            DetailCard(note: pace == nil
                       ? "Dots are the days you weighed in; the line is the 7-day average, which evens out water and meals."
                       : "Dots are the days you weighed in; the line is the 7-day average. The band is your goal's pace from four weeks ago.") {
                VStack(alignment: .leading, spacing: 14) {
                    if shown.count >= 2, let weight {
                        headline
                        WeightChart(readings: weight.readings, selected: $selected, from: firstShown, pace: pace)
                            .frame(height: 220)
                    } else {
                        Text("Fewer than two weigh-ins in these days.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let picked {
                Text(picked.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(WeightSummary.kg(picked.kg)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else if let first = shown.first, let last = shown.last, shown.count >= 2 {
                Text((period == .week ? "THIS WEEK" : period == .month ? "LAST 30 DAYS" : "LAST 6 MONTHS"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(WeightSummary.signed(last.kg - first.kg, digits: 1)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            }
        }
        .frame(minHeight: 64, alignment: .bottomLeading)
        .contentTransition(.numericText())
        .animation(.snappy, value: picked?.date)
    }

    // MARK: Day by day

    @ViewBuilder private var dayByDay: some View {
        let all = Array(shown.reversed())
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DetailCard("Day by day", padding: 0) {
                    ForEach(Array((showAll ? all : Array(all.prefix(14))).enumerated()), id: \.element.date) { i, r in
                        if i > 0 { RowDivider(leading: 16) }
                        dayRow(r)
                    }
                }
                if all.count > 14 && !showAll {
                    Chip(title: "Show all \(all.count)") { withAnimation(.snappy) { showAll = true } }
                }
            }
        }
    }

    private func dayRow(_ r: WeightReading) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(HealthDayName.of(r.date)).font(.body.weight(.medium))
                Text(r.source == "aide" ? "Logged in Aide" : "Apple Health").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(WeightSummary.kg(r.kg)).font(.body.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if r.source == "aide", let id = r.id {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete(id) } }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Loading

    private func load() async {
        do {
            weight = try await env.api.weight(days: 180)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func delete(_ id: Int) async {
        do {
            try await env.api.deleteWeight(id)
            await load()
            await health.writeWeights()
            await changed()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "Log weight": a number in kg (a comma or a point), sent to the server, then written to Apple Health.
private struct WeightEntry: ViewModifier {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var health: HealthService
    @Binding var isPresented: Bool
    let logged: () async -> Void
    @State private var text = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Log weight", isPresented: $isPresented) {
                TextField("72.4", text: $text).keyboardType(.decimalPad)
                Button("Cancel", role: .cancel) { text = "" }
                Button("Log") {
                    let kg = Double(text.replacingOccurrences(of: ",", with: "."))
                    text = ""
                    if let kg { Task { await log(kg) } }
                }
            } message: {
                Text("Kilograms, this morning before breakfast if you can.")
            }
            .alert("Couldn't log it", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func log(_ kg: Double) async {
        do {
            _ = try await env.api.logWeight(kg)
            await logged()
            await health.writeWeights()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    func weightEntry(isPresented: Binding<Bool>, logged: @escaping () async -> Void) -> some View {
        modifier(WeightEntry(isPresented: isPresented, logged: logged))
    }
}

/// The weight on the targets page: the average and the trend against the goal, opening the weight page.
struct WeightTargetsRow: View {
    let summary: WeightSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scalemass.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(WeightSummary.color)
                .frame(width: 34, height: 34)
                .background(WeightSummary.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                if let v = summary.shown {
                    Text(WeightSummary.kg(v) + (summary.shownLabel.map { " · \($0)" } ?? ""))
                        .font(.body.weight(.medium)).monospacedDigit()
                } else {
                    Text("No weight yet").font(.body.weight(.medium))
                }
                Text(summary.trendLine)
                    .font(.footnote)
                    .foregroundStyle(summary.isOff ? .orange : summary.verdict == "on_track" ? .green : .secondary)
            }
        }
    }
}
