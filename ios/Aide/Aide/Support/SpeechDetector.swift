import Foundation

/// Decides from the microphone's loudness when you're talking, measured against the room rather than a fixed bar.
/// Fed one level per microphone buffer, in dBFS (0 is the loudest the mic can give, silence is around -100).
///
/// - The first moments after the microphone starts don't count: voice processing is still settling.
/// - The room's noise is a low percentile of the last few seconds, so it follows a fan or a street but not you.
/// - You start talking at `overNoise` dB above that, and at least `quietest`, for `holdFor` in a row (a click or
///   a breath doesn't).
/// - Then only sounds within `belowPeak` dB of your loudest so far count as more talking, so the room between
///   your sentences (a TV, people) doesn't keep the turn open. Measured on the phone: a voice at -15 to -40 dB,
///   the room between sentences at -50 to -60.
/// - Over Aide's own voice it takes more to start: louder and longer (`strict`).
///
/// Voice processing hands over about ten buffers a second.
struct SpeechDetector {
    var settle: TimeInterval = 0.3
    var window: TimeInterval = 3
    var overNoise = 12.0
    var quietest = -65.0
    var holdFor: TimeInterval = 0.25
    var belowPeak = 30.0
    /// Over Aide's voice: this much louder again, for this long.
    var strictExtra = 10.0
    var strictHoldFor: TimeInterval = 0.25

    private(set) var elapsed: TimeInterval = 0
    private var recent: [(at: TimeInterval, db: Double)] = []
    private var loudFor: TimeInterval = 0

    /// The room's noise, once a moment has been heard. It stays put while you talk.
    private(set) var noise: Double?
    /// Your loudest this turn, once you've started.
    private(set) var peak: Double?

    /// To start talking.
    var bar: Double { max(quietest, (noise ?? quietest) + overNoise) }
    /// To count as more talking, once started.
    var talkingBar: Double { max(bar, (peak ?? bar) - belowPeak) }

    /// Starts over, for a microphone that has just (re)started.
    mutating func reset() {
        self = SpeechDetector(settle: settle, window: window, overNoise: overNoise, quietest: quietest,
                              holdFor: holdFor, belowPeak: belowPeak, strictExtra: strictExtra,
                              strictHoldFor: strictHoldFor)
    }

    /// A new turn: waiting for you to start again. The room's noise carries on.
    mutating func newTurn() {
        peak = nil
        loudFor = 0
    }

    /// One buffer: `db` loud, lasting `duration`. True when it's you talking.
    mutating func feed(_ db: Double, duration: TimeInterval, strict: Bool = false) -> Bool {
        elapsed += duration
        guard elapsed > settle else { return false }
        if let peak {
            guard db > talkingBar else { return false }
            self.peak = max(peak, db)
            return true
        }
        recent.append((elapsed, db))
        recent.removeAll { $0.at < elapsed - window }
        let sorted = recent.map(\.db).sorted()
        noise = sorted[sorted.count / 10]
        let loud = db > bar + (strict ? strictExtra : 0)
        loudFor = loud ? loudFor + duration : 0
        guard loudFor >= (strict ? strictHoldFor : holdFor) else { return false }
        peak = db
        return true
    }

    /// dBFS of float samples, from their root mean square (every 4th sample is plenty).
    static func decibels(_ samples: UnsafePointer<Float>, count: Int) -> Double {
        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 4) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(max(1, count / 4)))
        return 20 * log10(Double(max(rms, 1e-5)))
    }
}
