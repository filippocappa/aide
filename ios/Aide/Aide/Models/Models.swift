import Foundation

// Wire types for docs/API.md. Field names are snake_case on the wire; the decoder/encoder convert.

struct PendingAction: Codable, Identifiable, Hashable {
    let id: Int
    let summary: String
}

struct ChatReply: Decodable {
    let reply: String
    let pending: [PendingAction]
    let conversationId: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decode(String.self, forKey: .reply)
        pending = try c.decodeIfPresent([PendingAction].self, forKey: .pending) ?? []
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
    }
    private enum CodingKeys: String, CodingKey { case reply, pending, conversationId }
}

struct ActionResult: Decodable {
    let result: String
    let pending: [PendingAction]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(String.self, forKey: .result)
        pending = try c.decodeIfPresent([PendingAction].self, forKey: .pending) ?? []
    }
    private enum CodingKeys: String, CodingKey { case result, pending }
}

struct OKResponse: Decodable { let ok: Bool }
struct HealthResponse: Decodable { let ok: Bool; let version: String }
struct EmptyBody: Encodable {}
/// `conversationId` nil keeps the old behaviour: the one shared conversation.
struct ChatRequest: Encodable { let text: String; var conversationId: String? }
struct ConversationBody: Encodable { var conversationId: String? }
struct MemoryRequest: Encodable { let text: String }

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let preview: String?
    let updatedAt: String?
}
struct ConversationList: Decodable { let conversations: [Conversation] }

struct MemoryItem: Decodable, Identifiable, Hashable {
    let id: Int
    let text: String
    let createdAt: String?
}
struct MemoryList: Decodable { let items: [MemoryItem] }

struct HistoryMessage: Decodable {
    let role: String
    let text: String
    let ts: String?
}

struct HistoryResponse: Decodable { let messages: [HistoryMessage] }

struct CalendarEvent: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let calendar: String?
    let start: String
    let end: String
    let allDay: Bool
    let location: String?
    let recurring: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        calendar = try c.decodeIfPresent(String.self, forKey: .calendar)
        start = try c.decode(String.self, forKey: .start)
        end = try c.decode(String.self, forKey: .end)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
        recurring = try c.decodeIfPresent(Bool.self, forKey: .recurring) ?? false
    }
    private enum CodingKeys: String, CodingKey { case id, title, calendar, start, end, allDay, location, recurring }

    var startDate: Date? { allDay ? Wire.day(start) : Wire.parse(start) }
    var endDate: Date? { allDay ? Wire.day(end) : Wire.parse(end) }

    /// "All day" or "15:00 – 16:00".
    var timeText: String {
        guard !allDay, let s = startDate else { return "All day" }
        let from = s.formatted(date: .omitted, time: .shortened)
        guard let e = endDate else { return from }
        return "\(from) – \(e.formatted(date: .omitted, time: .shortened))"
    }
}

struct Reminder: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var notes: String
    var dueAt: String?
    var completed: Bool
    var appleId: String?
    var modifiedAt: String
    var deleted: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        appleId = try c.decodeIfPresent(String.self, forKey: .appleId)
        modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
    private enum CodingKeys: String, CodingKey { case id, title, notes, dueAt, completed, appleId, modifiedAt, deleted }

    var dueDate: Date? { dueAt.flatMap(Wire.parse) }
}

struct TodayResponse: Decodable {
    let date: String
    let events: [CalendarEvent]
    let reminders: [Reminder]
}

// MARK: - Habits and digest

struct Habit: Decodable, Identifiable, Hashable {
    struct Cadence: Decodable, Hashable {
        let type: String
        let perWeek: Int?
    }
    let id: Int
    let name: String
    let cadence: Cadence
    var streak: Int
    var doneToday: Bool
    let lastDone: String?

    var cadenceText: String {
        cadence.type == "weekly" ? "\(cadence.perWeek ?? 1)× a week" : "Every day"
    }
}
struct HabitList: Decodable { let habits: [Habit] }
struct HabitCheck: Encodable { var done: Bool }
struct HabitNew: Encodable {
    struct Cadence: Encodable { var type: String; var perWeek: Int? }
    var name: String
    var cadence: Cadence
}

struct MailItem: Decodable, Identifiable, Hashable {
    let id: String
    let from: String
    let subject: String
    let preview: String?
    let receivedAt: String?
    let unread: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? "(no subject)"
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        receivedAt = try c.decodeIfPresent(String.self, forKey: .receivedAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }
    private enum CodingKeys: String, CodingKey { case id, from, subject, preview, receivedAt, unread }
}

struct DigestSection: Decodable, Identifiable {
    enum Content {
        case calendar([CalendarEvent])
        case mail([MailItem])
        case reminders([Reminder])
        case habits([Habit])
        case text(String)
        case unknown // a section type this app version doesn't know: skipped
    }
    let id = UUID()
    let title: String
    let content: Content

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        switch try c.decode(String.self, forKey: .type) {
        case "calendar": content = .calendar(try c.decode([CalendarEvent].self, forKey: .events))
        case "mail": content = .mail(try c.decode([MailItem].self, forKey: .items))
        case "reminders": content = .reminders(try c.decode([Reminder].self, forKey: .reminders))
        case "habits": content = .habits(try c.decode([Habit].self, forKey: .habits))
        case "text": content = .text(try c.decode(String.self, forKey: .text))
        default: content = .unknown
        }
    }
    private enum CodingKeys: String, CodingKey { case type, title, events, items, reminders, habits, text }
}

struct Digest: Decodable {
    let kind: String
    let generatedAt: String?
    let greeting: String
    let sections: [DigestSection]
}

struct DigestSchedule: Codable, Equatable {
    var enabled: Bool
    var time: String // "HH:MM" in the server's zone
    var weekday: Int? // weekly: 1 = Monday
    var day: Int? // monthly: 1–31
}

struct DigestSettings: Codable, Equatable {
    var daily: DigestSchedule // the morning digest
    var evening: DigestSchedule?
    var weekly: DigestSchedule
    var monthly: DigestSchedule
    var discord: Bool
}

// MARK: - Reminder sync

/// A reminder changed on the phone. Nullable fields are always sent (`"id": null` means created on the phone).
struct ReminderChange: Encodable, Equatable {
    var id: String?
    var appleId: String
    var title: String
    var notes: String
    var dueAt: String?
    var completed: Bool
    var modifiedAt: String
    var deleted: Bool

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(appleId, forKey: .appleId)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(dueAt, forKey: .dueAt)
        try c.encode(completed, forKey: .completed)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(deleted, forKey: .deleted)
    }
    private enum CodingKeys: String, CodingKey { case id, appleId, title, notes, dueAt, completed, modifiedAt, deleted }
}

struct SyncRequest: Encodable {
    var cursor: String?
    var changes: [ReminderChange]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(changes, forKey: .changes)
    }
    private enum CodingKeys: String, CodingKey { case cursor, changes }
}

struct SyncResponse: Decodable {
    let cursor: String
    let reminders: [Reminder]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The cursor is opaque; accept a number in case the server sends one.
        if let s = try? c.decode(String.self, forKey: .cursor) {
            cursor = s
        } else {
            cursor = String(try c.decode(Int.self, forKey: .cursor))
        }
        reminders = try c.decode([Reminder].self, forKey: .reminders)
    }
    private enum CodingKeys: String, CodingKey { case cursor, reminders }
}

// MARK: - Dates

/// ISO 8601 with offset for times, `YYYY-MM-DD` for days.
enum Wire {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }

    /// UTC, e.g. `2026-10-18T11:20:00Z`. For `modified_at`.
    static func utc(_ d: Date) -> String { plain.string(from: d) }

    /// Local offset, e.g. `2026-10-20T17:00:00+02:00`. For `due_at`.
    static func local(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: d)
    }

    static func day(_ s: String) -> Date? { dayFormatter.date(from: s) }
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
