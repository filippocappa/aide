import Foundation

/// A piece of a night as Apple Health stores it, already read out of HealthKit.
struct SleepSegment: Equatable {
    enum Stage { case inBed, awake, asleep, core, deep, rem }
    let stage: Stage
    let start: Date
    let end: Date
}

/// Turns sleep segments into the night that ended on a day (docs/API.md, "Health day"). No HealthKit here,
/// so it can be tested.
enum SleepSummary {
    /// Gaps shorter than this still belong to the same night.
    static let maxGap: TimeInterval = 60 * 60

    static func night(endingOn day: Date, from segments: [SleepSegment], calendar: Calendar = .current) -> SleepNight? {
        let midnight = calendar.startOfDay(for: day)
        guard let windowEnd = calendar.date(byAdding: .hour, value: 18, to: midnight),
              let windowStart = calendar.date(byAdding: .day, value: -1, to: windowEnd)
        else { return nil }

        // The Watch writes stages; the iPhone only "asleep". When there are stages, the plain ones are duplicates.
        let staged = segments.filter { [.core, .deep, .rem].contains($0.stage) }
        let asleep = staged.isEmpty ? segments.filter { $0.stage == .asleep } : staged

        let night = sessions(merge(asleep.map { ($0.start, $0.end) }))
            .filter { $0.end > windowStart && $0.end <= windowEnd }
            .max { asleepTime($0.parts) < asleepTime($1.parts) }
        guard let night else { return nil }

        func minutes(_ stage: SleepSegment.Stage) -> Int? {
            guard !staged.isEmpty else { return nil }
            let parts = staged.filter { $0.stage == stage }.map { ($0.start, $0.end) }
            return Int((asleepTime(merge(clip(parts, night.start, night.end))) / 60).rounded())
        }

        let asleepMin = Int((asleepTime(night.parts) / 60).rounded())
        let inBedMin = Int((night.end.timeIntervalSince(night.start) / 60).rounded())
        return SleepNight(bedtime: Wire.local(night.start), wake: Wire.local(night.end),
                          asleepMin: asleepMin, inBedMin: inBedMin, awakeMin: max(0, inBedMin - asleepMin),
                          deepMin: minutes(.deep), coreMin: minutes(.core), remMin: minutes(.rem))
    }

    private typealias Interval = (start: Date, end: Date)
    private struct Session { var start: Date; var end: Date; var parts: [Interval] }

    /// Overlapping intervals joined into one, sorted.
    private static func merge(_ intervals: [Interval]) -> [Interval] {
        var out: [Interval] = []
        for i in intervals.sorted(by: { $0.start < $1.start }) where i.end > i.start {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1].end = max(last.end, i.end)
            } else {
                out.append(i)
            }
        }
        return out
    }

    /// Sorted, non-overlapping intervals grouped into stretches with gaps under `maxGap`.
    private static func sessions(_ merged: [Interval]) -> [Session] {
        var out: [Session] = []
        for i in merged {
            if let last = out.last, i.start.timeIntervalSince(last.end) < maxGap {
                out[out.count - 1].end = i.end
                out[out.count - 1].parts.append(i)
            } else {
                out.append(Session(start: i.start, end: i.end, parts: [i]))
            }
        }
        return out
    }

    private static func clip(_ intervals: [Interval], _ from: Date, _ to: Date) -> [Interval] {
        intervals.compactMap { i in
            let s = max(i.start, from), e = min(i.end, to)
            return e > s ? (s, e) : nil
        }
    }

    private static func asleepTime(_ intervals: [Interval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}
