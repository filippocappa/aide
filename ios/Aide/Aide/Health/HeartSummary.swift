import Foundation

/// One heart-rate sample: when, and its bpm (a series sample's average and its top).
struct HeartReading {
    let start: Date
    let end: Date
    let bpm: Double
    let top: Double
}

/// A day's heart rate as the server takes it for Strain (docs/API.md, "Health day"): minutes per 5-bpm bucket from
/// 90 bpm up, hourly averages for the day chart, and the day's top. Summaries only; the samples stay on the phone.
struct HeartSummary: Equatable {
    /// `[bpm_floor, minutes]`, lowest first, buckets with no time left out.
    var minutes: [[Double]] = []
    /// 24 averages, 00:00 to 23:00; nil for an hour with no sample.
    var hourly: [Int?] = []
    var max: Int?

    static let floor = 90.0
    static let width = 5.0
    /// A sample counts until the next one, at most this long (the Watch measures every few minutes at rest).
    static let hold: TimeInterval = 600

    init() {}

    /// `readings` sorted by start, the ones that start on the day (`day` to `next`).
    init(_ readings: [HeartReading], day: Date, next: Date, calendar: Calendar) {
        guard !readings.isEmpty else { return }
        var buckets: [Double: TimeInterval] = [:]
        var hours = [(sum: Double, count: Int)](repeating: (0, 0), count: 24)
        for (i, r) in readings.enumerated() {
            let following = i + 1 < readings.count ? readings[i + 1].start : next
            let end = r.end > r.start ? r.end : min(following, r.start.addingTimeInterval(Self.hold))
            let seconds = Swift.min(end, next).timeIntervalSince(Swift.max(r.start, day))
            if r.bpm >= Self.floor, seconds > 0 {
                buckets[(r.bpm / Self.width).rounded(.down) * Self.width, default: 0] += seconds
            }
            let hour = calendar.component(.hour, from: r.start)
            hours[hour].sum += r.bpm
            hours[hour].count += 1
        }
        minutes = buckets.keys.sorted().compactMap { bpm in
            let m = (buckets[bpm]! / 30).rounded() / 2 // to the half minute
            return m > 0 ? [bpm, m] : nil
        }
        hourly = hours.map { $0.count > 0 ? Int(($0.sum / Double($0.count)).rounded()) : nil }
        max = readings.map(\.top).max().map { Int($0.rounded()) }
    }
}

/// The night's heart rate while asleep (docs/API.md, "Health day": `sleep_hr`, `sleep_hr_low`), what recovery reads:
/// the average over the sleep stages, and the lowest average of 3 readings in a row (~15 min), so one dip doesn't count.
struct AsleepHeart: Equatable {
    let avg: Int
    let low: Int

    static let minReadings = 6

    init(avg: Int, low: Int) {
        self.avg = avg
        self.low = low
    }

    /// `readings` sorted by start; `asleep` the night's sleep stages (awake stretches left out).
    init?(_ readings: [HeartReading], asleep: [(start: Date, end: Date)]) {
        let bpm = readings.filter { r in asleep.contains { r.start >= $0.start && r.start < $0.end } }.map(\.bpm)
        guard bpm.count >= Self.minReadings else { return nil }
        avg = Int((bpm.reduce(0, +) / Double(bpm.count)).rounded())
        low = Int((0...(bpm.count - 3)).map { bpm[$0..<$0 + 3].reduce(0, +) / 3 }.min()!.rounded())
    }
}
