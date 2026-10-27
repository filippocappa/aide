import Foundation

/// A Screen Time lock (docs/API.md, "Screen Time"), as the server sends it. Dates are ISO strings with an offset.
struct ScreenLock: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    /// A one-off, from `startsAt` to `endsAt`; else a schedule, `start` to `end` on `days`.
    let once: Bool
    /// HH:MM local; an `end` before the `start` is the next morning.
    let start: String?
    let end: String?
    /// ISO weekdays it starts on, [] every day. nil on a one-off.
    let days: [Int]?
    let startsAt: String?
    let endsAt: String?
    var enabled: Bool
    /// Ends early only with an emergency pass; while it's on, the Screen Time page is locked. nil from an older server.
    let strict: Bool?
    /// Who set it ("coach"); nil: you, in the app.
    let agent: String?
    /// On now, until `until`.
    let locked: Bool
    let until: String?
    /// Unlocked early this time, open until then.
    let openUntil: String?
    let next: String?
    let summary: String

    var isStrict: Bool { strict == true }
}
