import Charts
import SwiftUI

// Weight (docs/API.md, "Apple Health", Weight): Apple Health's readings and the ones logged through Aide, the 7-day
// average and the trend against the pace the food goal wants. A card on Health → Body, a page with the chart and the
// days, a row on the targets page, and "Log weight", which the phone also writes to Health.

extension WeightSummary {
    static let color = Color.teal

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

/// The weight on Health → Body: the number, the trend, the last month in small, and Log weight.
struct WeightCard: View {
    let weight: WeightList
    let open: () -> Void
    let log: () -> Void

    var body: some View {
        let s = weight.summary
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
                Text(s.trendLine)
                    .font(.subheadline)
                    .foregroundStyle(s.isOff ? .orange : s.verdict == "on_track" ? .green : .secondary)
                if weight.readings.count >= 2 {
                    WeightChart(readings: Array(weight.readings.suffix(30)), small: true)
                        .frame(height: 44)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the chart")
        Button(action: log) {
            Label("Log weight", systemImage: "plus.circle.fill")
        }
    }
}

/// The readings as dots and the 7-day average as a line, oldest on the left.
struct WeightChart: View {
    /// Oldest first.
    let readings: [WeightReading]
    var small = false
    var selected: Binding<Date?>? = nil

    /// Each reading's day and the mean of the readings in the 7 days up to it.
    static func averages(_ readings: [WeightReading]) -> [(date: Date, kg: Double, average: Double)] {
        let dated = readings.compactMap { r in Wire.day(r.date).map { (date: $0, kg: r.kg) } }
        return dated.map { item in
            let week = dated.filter { $0.date <= item.date && item.date.timeIntervalSince($0.date) < 7 * 86_400 }
            return (item.date, item.kg, week.map(\.kg).reduce(0, +) / Double(week.count))
        }
    }

    var body: some View {
        let points = Self.averages(readings)
        let kgs = points.flatMap { [$0.kg, $0.average] }
        let lo = (kgs.min() ?? 0) - 0.5, hi = (kgs.max() ?? 1) + 0.5
        let chart = Chart {
            ForEach(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Average", p.average))
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

/// The weight page: the chart over 30 or 90 days, the trend against the goal, and the days (swipe one logged through
/// Aide to delete it).
struct WeightView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var health: HealthService
    /// Something was logged or deleted here.
    var changed: () async -> Void = {}

    @State private var weight: WeightList?
    @State private var error: String?
    @State private var range = 30
    @State private var selected: Date?
    @State private var logging = false

    private var shown: [WeightReading] {
        guard let weight, let first = Calendar.current.date(byAdding: .day, value: 1 - range, to: Date()) else { return [] }
        let from = Wire.dayString(first)
        return weight.readings.filter { $0.date >= from }
    }

    private var picked: (date: Date, kg: Double, average: Double)? {
        guard let selected else { return nil }
        return WeightChart.averages(shown).min {
            abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
        }
    }

    var body: some View {
        List {
            if let weight {
                Section {
                    Picker("Range", selection: $range) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        headline(weight.summary)
                        if shown.count >= 2 {
                            WeightChart(readings: shown, selected: $selected).frame(height: 220)
                        }
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text("Dots are the days you weighed in; the line is the 7-day average, which evens out water and meals.")
                }
                .listRowBackground(Theme.row)
                trend(weight.summary)
                Section("Day by day") {
                    if shown.isEmpty { Text("No readings in these days").foregroundStyle(.secondary) }
                    ForEach(shown.reversed(), id: \.date) { r in
                        LabeledContent {
                            Text(WeightSummary.kg(r.kg)).monospacedDigit()
                        } label: {
                            Text(HealthDayName.of(r.date))
                            Text(r.source == "aide" ? "Logged in Aide" : "Apple Health")
                        }
                        .swipeActions {
                            if r.source == "aide", let id = r.id {
                                Button("Delete", role: .destructive) { Task { await delete(id) } }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.row)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Weight")
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
        .refreshable { await load() }
        .task { await load() }
    }

    private func headline(_ s: WeightSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let picked {
                Text(picked.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(WeightSummary.kg(picked.kg)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else if let v = s.shown {
                Text((s.shownLabel ?? "").uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(WeightSummary.kg(v)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            } else {
                Text("No weight yet. Log one, or weigh in on a scale that writes to Apple Health.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 64, alignment: .bottomLeading)
        .contentTransition(.numericText())
        .animation(.snappy, value: picked?.date)
    }

    @ViewBuilder private func trend(_ s: WeightSummary) -> some View {
        if s.latest != nil {
            Section {
                if let rate = s.rateText { LabeledContent("Trend", value: rate) }
                if let change = s.changeKg { LabeledContent("Over 3 weeks", value: WeightSummary.signed(change, digits: 1)) }
                if let pace = s.paceText { LabeledContent("Your goal wants", value: pace) }
                if let verdict = s.verdictText {
                    Label(verdict, systemImage: s.isOff ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(s.isOff ? .orange : .green)
                }
            } header: {
                Text("Trend")
            } footer: {
                if s.isOff {
                    Text("Off the pace for a while? Coach checks on Mondays, or ask for new targets in Settings → Nutrition targets.")
                } else if s.rateKgWeek == nil {
                    Text("The trend needs three weigh-ins over two weeks. Weigh in in the morning, before breakfast.")
                } else {
                    Text("A straight line through the last four weeks. The pace is from your goal in Nutrition targets.")
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    private func load() async {
        do {
            weight = try await env.api.weight(days: 90)
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
