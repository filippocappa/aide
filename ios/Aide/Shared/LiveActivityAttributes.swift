import ActivityKit
import Foundation

// The two Live Activities (docs/API.md, "Live Activities"). The server sends these fields in its pushes, so the
// names are the contract's, and times are Unix seconds: ActivityKit decodes the JSON with no date strategy.

/// A tram alert's countdown, started by the server when the alert fires.
struct TramActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the tram is expected at the stop, live delay included.
        var at: Double
        /// When to leave to make it; nil for an "N minutes away" alert.
        var leave: Double?
        /// Seconds from the phone to the stop, nil when the location isn't known.
        var walk: Int?
        /// false: timetable only.
        var live: Bool
        /// Seconds late (negative: early), nil when not live.
        var delay: Int?
        /// The next one's expected time.
        var next: Double?
        /// The tram has left the stop.
        var gone: Bool
        /// Stops it has still to reach before yours (0: yours is its next). nil from older servers, or not known.
        var stops: Int? = nil
        /// The stop it's at or has just left (its first stop, before it sets off).
        var near: String? = nil
        /// When it leaves its first stop, if it hasn't yet.
        var starts: Double? = nil
        /// GTT's live feed isn't coming through: every tram is on the timetable.
        var feedDown: Bool? = nil
        /// The phone is at the stop.
        var atStop: Bool? = nil
        /// The user is on it: `at` is when it gets to `to` (or to `near`, its next stop), `stops` the stops before `to`.
        var riding: Bool? = nil
        /// Where the user gets off, when known.
        var to: String? = nil

        enum CodingKeys: String, CodingKey {
            case at, leave, walk, live, delay, next, gone, stops, near, starts, riding, to
            case feedDown = "feed_down"
            case atStop = "at_stop"
        }

        var isRiding: Bool { riding == true }

        var atDate: Date { Date(timeIntervalSince1970: at) }
        var startsDate: Date? { starts.map(Date.init(timeIntervalSince1970:)) }
        var leaveDate: Date? { leave.map(Date.init(timeIntervalSince1970:)) }
        var nextDate: Date? { next.map(Date.init(timeIntervalSince1970:)) }
    }

    /// `tram:<alert id>:<trip>:<service day>`
    var key: String
    var line: String
    /// Tram, Bus, Metro or Train.
    var vehicle: String
    /// The stop's name, and the number on its sign.
    var stop: String
    var code: String
    var towards: String?
    var alert: Int
}

/// An agent at work: on a chat reply (started here, kept up to date by the server) or a scheduled routine (started
/// by the server).
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// working, asking, writing, done or failed.
        var status: String
        /// "Asking Coach", or what went wrong.
        var detail: String
        /// The reply's first line, once it's done.
        var text: String
        /// When it started working.
        var since: Double

        var sinceDate: Date { Date(timeIntervalSince1970: since) }
        var isOver: Bool { status == "done" || status == "failed" }

        static func working(since: Date = Date()) -> ContentState {
            ContentState(status: "working", detail: "", text: "", since: since.timeIntervalSince1970)
        }
    }

    /// `agent:<conversation id>`, or `agent:team`.
    var key: String
    var agent: String
    var name: String
    /// "#RRGGBB"
    var color: String
    /// The conversation id, or "team".
    var conversation: String
    /// The routine's title; nil for a chat.
    var title: String?

    /// Where a tap goes (PushRoute).
    var url: URL? {
        URL(string: conversation == "team" ? "aide://team" : "aide://conversation/\(conversation)")
    }
}

extension AgentActivityAttributes.ContentState {
    /// What it's doing, in a line.
    func line(name: String) -> String {
        switch status {
        case "done": text.isEmpty ? "Done" : text
        case "failed": detail.isEmpty ? "Something went wrong" : detail
        case "asking", "writing": detail.isEmpty ? (status == "asking" ? "\(name) is asking the team" : "\(name) is writing")
                                                 : detail
        default: detail.isEmpty ? "\(name) is working on it" : detail
        }
    }
}
