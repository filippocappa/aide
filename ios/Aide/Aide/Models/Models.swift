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
    let attachments: [Attachment]
    /// Agents Aide asked during the turn (docs/API.md, "Agents").
    let consulted: [String]
    /// What Aide and those agents said to each other.
    let team: [TeamMessage]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decode(String.self, forKey: .reply)
        pending = try c.decodeIfPresent([PendingAction].self, forKey: .pending) ?? []
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        attachments = Attachment.known(try c.decodeIfPresent([Attachment].self, forKey: .attachments))
        consulted = try c.decodeIfPresent([String].self, forKey: .consulted) ?? []
        team = try c.decodeIfPresent([TeamMessage].self, forKey: .team) ?? []
    }
    private enum CodingKeys: String, CodingKey { case reply, pending, conversationId, attachments, consulted, team }
}

/// One message in the agents' group chat: an ask from Aide, or an agent's answer (docs/API.md, "Team talk").
struct TeamMessage: Decodable, Hashable {
    let from: String
    let to: String
    let text: String
    var ts: String?
    /// Aide's chat it came from; only in `GET /v1/team`.
    var conversationId: String?
}

struct TeamList: Decodable { let messages: [TeamMessage] }
struct TeamPost: Encodable { let text: String; var stream: Bool? }
/// What `POST /v1/team` adds: your message first, then the answers.
struct TeamReply: Decodable {
    let messages: [TeamMessage]
    let pending: [PendingAction]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([TeamMessage].self, forKey: .messages) ?? []
        pending = try c.decodeIfPresent([PendingAction].self, forKey: .pending) ?? []
    }
    private enum CodingKeys: String, CodingKey { case messages, pending }
}

/// `event: error` in a streamed chat.
struct StreamError: Decodable { let error: String }

/// Cards under a reply, built by the server from the tools that turn used (docs/API.md, "Chat").
enum Attachment: Decodable, Hashable {
    case reminders([Reminder])
    case events([CalendarEvent])
    case meals([Meal])
    case unknown // a type this app version doesn't know: skipped

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "reminders": self = .reminders(try c.decode([Reminder].self, forKey: .reminders))
        case "events": self = .events(try c.decode([CalendarEvent].self, forKey: .events))
        case "meals": self = .meals(try c.decode([Meal].self, forKey: .meals))
        default: self = .unknown
        }
    }
    private enum CodingKeys: String, CodingKey { case type, reminders, events, meals }

    static func known(_ list: [Attachment]?) -> [Attachment] {
        (list ?? []).filter { $0 != .unknown }
    }
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
/// `digest` and `agent` nil send `{}`: a blank chat with Aide.
struct NewConversation: Encodable { var digest: String?; var agent: String? }
/// `conversationId` nil keeps the old behaviour: the one shared conversation. `photos` nil when there are none.
struct ChatRequest: Encodable { let text: String; var conversationId: String?; var stream: Bool?; var photos: [String]? }
struct PhotoUpload: Decodable { let id: String }
struct ConversationBody: Encodable { var conversationId: String? }
/// `agent` nil: shared by every agent.
struct MemoryRequest: Encodable { let text: String; var agent: String? }
/// `environment` is "sandbox" for Xcode builds, "production" for TestFlight and the App Store.
struct DeviceRegistration: Encodable { let token: String; let environment: String; let name: String }
struct PushTestResult: Decodable { let sent: Int; let failed: Int }

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    /// nil from older servers: Aide's.
    let agent: String?
    let title: String?
    let preview: String?
    let updatedAt: String?
    /// The routine this chat belongs to (docs/API.md, "Routines").
    var routine: Int? = nil
    /// The course this chat is Professor's chat for (docs/API.md, "Notebook").
    var course: Int? = nil
}
struct ConversationList: Decodable { let conversations: [Conversation] }

struct MemoryItem: Decodable, Identifiable, Hashable {
    let id: Int
    let text: String
    /// nil: shared by every agent.
    let agent: String?
    let createdAt: String?
}
struct MemoryList: Decodable { let items: [MemoryItem] }

struct HistoryMessage: Decodable {
    let role: String
    let text: String
    let ts: String?
    /// Reminders in here are in their current state: ticked or deleted since.
    let attachments: [Attachment]
    let consulted: [String]
    let team: [TeamMessage]
    /// Set when a routine posted it.
    let routine: RoutineTag?
    /// Photo ids sent with a user message (docs/API.md, "Photos").
    let photos: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routine = try c.decodeIfPresent(RoutineTag.self, forKey: .routine)
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
        attachments = Attachment.known(try c.decodeIfPresent([Attachment].self, forKey: .attachments))
        consulted = try c.decodeIfPresent([String].self, forKey: .consulted) ?? []
        team = try c.decodeIfPresent([TeamMessage].self, forKey: .team) ?? []
    }
    private enum CodingKeys: String, CodingKey { case role, text, ts, attachments, consulted, team, routine, photos }
}

struct RoutineTag: Decodable, Hashable {
    let id: Int
    let title: String
}

/// Aide (the orchestrator) or one of the specialists (docs/API.md, "Agents").
struct Agent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    /// "#RRGGBB", Pebble's colour on light backgrounds.
    let color: String
    let orchestrator: Bool
    /// Empty-chat suggestions; one ending in a space goes into the text field instead of being sent.
    let starters: [String]
    /// One-tap starting points for its routines.
    var routineIdeas: [RoutineIdea] = []
    /// What it runs on, for its info screen: its instructions, its tools here, and those grouped by what they reach.
    var prompt = ""
    var tools: [String] = []
    var connectors: [Connector] = []

    struct Connector: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        /// None of its tools here change anything.
        let readOnly: Bool
        let tools: [String]
    }

    init(id: String, name: String, role: String, color: String, orchestrator: Bool, starters: [String],
         routineIdeas: [RoutineIdea] = []) {
        (self.id, self.name, self.role, self.color, self.orchestrator, self.starters) = (id, name, role, color, orchestrator, starters)
        self.routineIdeas = routineIdeas
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#34413F"
        orchestrator = try c.decodeIfPresent(Bool.self, forKey: .orchestrator) ?? false
        starters = try c.decodeIfPresent([String].self, forKey: .starters) ?? []
        routineIdeas = try c.decodeIfPresent([RoutineIdea].self, forKey: .routineIdeas) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        connectors = try c.decodeIfPresent([Connector].self, forKey: .connectors) ?? []
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, role, color, orchestrator, starters, routineIdeas, prompt, tools, connectors
    }

    /// What the app shows when the server has no agents yet: Aide alone, as before.
    static let aide = Agent(id: "aide", name: "Aide", role: "Talks to all of them", color: "#34413F", orchestrator: true,
                            starters: ["What's on my calendar today?", "Remind me to ", "Remember that "])

    /// The hex value, or nil if it isn't "#RRGGBB".
    var hex: UInt32? {
        let digits = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}
struct AgentList: Decodable { let agents: [Agent] }

/// A job an agent runs on a schedule, posting in its own chat (docs/API.md, "Routines").
struct Routine: Decodable, Identifiable, Hashable {
    let id: Int
    let agent: String
    var title: String
    var prompt: String
    /// "HH:MM", local time.
    var time: String
    /// ISO weekdays, 1 = Monday … 7 = Sunday; empty means every day.
    var days: [Int]
    var enabled: Bool
    /// A watch posts only when something needs you ("Watches"); absent from an older server.
    var watch: Bool?
    var conversationId: String?
    var nextRun: String?
    var lastRun: String?

    var isWatch: Bool { watch == true }
}
struct RoutineList: Decodable { let routines: [Routine] }
/// `spoke` is false when a watch found nothing and posted nothing.
struct RoutineRun: Decodable { let routine: Routine; let conversationId: String?; let spoke: Bool? }

/// What the app sends to create a routine (with `agent`) or change one (without).
struct RoutineDraft: Encodable, Hashable {
    var agent: String?
    var title: String
    var prompt: String
    var time: String
    var days: [Int]
    var enabled: Bool
    var watch = false
}

struct RoutineIdea: Decodable, Hashable {
    let title: String
    let prompt: String
    let time: String
    let days: [Int]
    let watch: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        prompt = try c.decode(String.self, forKey: .prompt)
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? "09:00"
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? false
    }
    private enum CodingKeys: String, CodingKey { case title, prompt, time, days, watch }
}

enum Schedule {
    /// "Every day at 09:00", "Weekdays at 09:00", "Sundays at 18:00", "Mon, Wed and Fri at 07:30".
    static func label(time: String, days: [Int]) -> String {
        let set = Set(days)
        let when: String
        switch set {
        case [], Set(1...7): when = "Every day"
        case Set(1...5): when = "Weekdays"
        case [6, 7]: when = "Weekends"
        default:
            // The symbols start on Sunday, so ISO 7 (Sunday) % 7 lands on 0.
            let names = DateFormatter(), sorted = set.sorted()
            when = sorted.count == 1 ? names.weekdaySymbols[sorted[0] % 7] + "s"
                : sorted.map { names.shortWeekdaySymbols[$0 % 7] }.formatted(.list(type: .and))
        }
        return "\(when) at \(time)"
    }
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
    /// Set in digests: due time has passed (the server lists only the last 48 h of those).
    var overdue: Bool
    /// Its Apple Reminders list, by name. Nil: the default list.
    var list: String?

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
        overdue = try c.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
        list = try c.decodeIfPresent(String.self, forKey: .list)
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, dueAt, completed, appleId, modifiedAt, deleted, overdue, list
    }

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
    /// Local dates ("2026-10-19") it was checked in the last 26 weeks. Missing from older servers.
    var history: [String]?
    /// Watch workout types that check it by themselves (docs/API.md, "Workout types"). Missing from older servers.
    var workouts: [String]?

    var cadenceText: String {
        cadence.type == "weekly" ? "\(cadence.perWeek ?? 1)× a week" : "Every day"
    }
}
struct HabitList: Decodable { let habits: [Habit] }
struct HabitCheck: Encodable { var done: Bool }
/// The body of `POST /v1/habits` and `PATCH /v1/habits/{id}`.
struct HabitNew: Encodable {
    struct Cadence: Encodable { var type: String; var perWeek: Int? }
    var name: String
    var cadence: Cadence
    var workouts: [String] = []
}

/// Labels for the workout types a habit can be checked by, in the order the picker shows them.
enum WorkoutType {
    static let all: [(id: String, label: String)] = [
        ("any", "Any workout"), ("strength", "Strength"), ("run", "Run"), ("walk", "Walk"), ("hike", "Hike"),
        ("cycle", "Cycling"), ("swim", "Swim"), ("hiit", "HIIT"), ("yoga", "Yoga"), ("pilates", "Pilates"),
        ("core", "Core"), ("dance", "Dance"), ("climb", "Climbing"), ("row", "Rowing"),
        ("elliptical", "Elliptical"), ("stairs", "Stairs"), ("cardio", "Cardio"),
        ("martial_arts", "Martial arts"), ("sport", "Sports"), ("other", "Other"),
    ]

    static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

// MARK: - Food

/// A meal Coach logged, its numbers the model's estimates (docs/API.md, "Food").
struct Meal: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var eatenAt: String
    var calories: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    /// Photo id, nil without one.
    var photo: String?
    var notes: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Meal"
        eatenAt = try c.decodeIfPresent(String.self, forKey: .eatenAt) ?? ""
        calories = try c.number(.calories) ?? 0
        proteinG = try c.number(.proteinG) ?? 0
        carbsG = try c.number(.carbsG) ?? 0
        fatG = try c.number(.fatG) ?? 0
        photo = try c.decodeIfPresent(String.self, forKey: .photo)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case id, name, eatenAt, calories, proteinG, carbsG, fatG, photo, notes }

    var eatenDate: Date? { Wire.parse(eatenAt) }
}

/// What was eaten in a day.
struct FoodTotals: Decodable, Hashable {
    var calories = 0
    var proteinG = 0
    var carbsG = 0
    var fatG = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calories = try c.number(.calories) ?? 0
        proteinG = try c.number(.proteinG) ?? 0
        carbsG = try c.number(.carbsG) ?? 0
        fatG = try c.number(.fatG) ?? 0
    }
    private enum CodingKeys: String, CodingKey { case calories, proteinG, carbsG, fatG }
}

/// Daily goals; nil is no goal. Saved with every key, so clearing one sends null.
struct FoodGoals: Codable, Hashable {
    var calories: Int?
    var proteinG: Int?
    var carbsG: Int?
    var fatG: Int?

    init(calories: Int? = nil, proteinG: Int? = nil, carbsG: Int? = nil, fatG: Int? = nil) {
        (self.calories, self.proteinG, self.carbsG, self.fatG) = (calories, proteinG, carbsG, fatG)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calories = try c.number(.calories)
        proteinG = try c.number(.proteinG)
        carbsG = try c.number(.carbsG)
        fatG = try c.number(.fatG)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calories, forKey: .calories)
        try c.encode(proteinG, forKey: .proteinG)
        try c.encode(carbsG, forKey: .carbsG)
        try c.encode(fatG, forKey: .fatG)
    }
    private enum CodingKeys: String, CodingKey { case calories, proteinG, carbsG, fatG }
}

/// `GET /v1/food`: one day's meals, by time.
struct FoodDay: Decodable {
    let date: String
    var meals: [Meal]
    var totals: FoodTotals
    var goals: FoodGoals

    init(date: String) {
        (self.date, meals, totals, goals) = (date, [], FoodTotals(), FoodGoals())
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        meals = try c.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        totals = try c.decodeIfPresent(FoodTotals.self, forKey: .totals) ?? FoodTotals()
        goals = try c.decodeIfPresent(FoodGoals.self, forKey: .goals) ?? FoodGoals()
    }
    private enum CodingKeys: String, CodingKey { case date, meals, totals, goals }
}

/// A day in `GET /v1/food/days`: its totals and how many meals.
struct FoodDaySummary: Decodable, Hashable {
    let date: String
    let totals: FoodTotals
    let meals: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        totals = try c.decodeIfPresent(FoodTotals.self, forKey: .totals) ?? FoodTotals()
        meals = try c.number(.meals) ?? 0
    }
    private enum CodingKeys: String, CodingKey { case date, totals, meals }
}
struct FoodDayList: Decodable { let days: [FoodDaySummary] }

/// `POST /v1/food/log`: photos, words or both. `date` nil is today.
struct FoodLogRequest: Encodable { var photos: [String] = []; var text: String?; var date: String? }
struct FoodLogReply: Decodable {
    let reply: String
    /// What Coach logged or changed; empty when it only asked something.
    let meals: [Meal]
    let conversationId: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        meals = try c.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
    }
    private enum CodingKeys: String, CodingKey { case reply, meals, conversationId }
}

/// The body of `PATCH /v1/food/meals/{id}`: the edit sheet sends every field.
struct MealChanges: Encodable, Equatable {
    var name: String
    var eatenAt: String
    var calories: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var notes: String
}

private extension KeyedDecodingContainer {
    /// A whole number the server might send as 650 or 650.0; nil when missing or null.
    func number(_ key: Key) throws -> Int? {
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n }
        return try decodeIfPresent(Double.self, forKey: key).map { Int($0.rounded()) }
    }
}

// MARK: - Apple Health

/// The night that ended on a health day's date (docs/API.md, "Health day").
struct SleepNight: Codable, Hashable {
    var bedtime: String
    var wake: String
    var asleepMin: Int
    var inBedMin: Int
    var awakeMin: Int?
    /// Stages are nil without a Watch.
    var deepMin: Int?
    var coreMin: Int?
    var remMin: Int?

    var bedtimeDate: Date? { Wire.parse(bedtime) }
    var wakeDate: Date? { Wire.parse(wake) }
}

struct HealthWorkout: Encodable, Equatable {
    var id: String
    var type: String
    var start: String
    var end: String
    var minutes: Int
    var kcal: Int?
}

/// One local day's summary. Nil fields are left out: no data.
struct HealthDay: Encodable, Equatable {
    var date: String
    var sleep: SleepNight?
    var restingHr: Int?
    var hrvMs: Double?
    var respiratoryRate: Double?
    var wristTempC: Double?
    var steps: Int?
    var activeKcal: Int?
    var exerciseMin: Int?
    var workouts: [HealthWorkout] = []
}

struct HealthUpload: Encodable { let days: [HealthDay] }
struct HealthUploadResult: Decodable {
    let saved: Int
    /// Habits this upload checked through workouts.
    let checked: [Habit]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = try c.decodeIfPresent(Int.self, forKey: .saved) ?? 0
        checked = try c.decodeIfPresent([Habit].self, forKey: .checked) ?? []
    }
    private enum CodingKeys: String, CodingKey { case saved, checked }
}

/// `source` is "shortcut" or "app".
struct WakeRequest: Encodable { let at: String; let source: String; let day: HealthDay? }
struct WakeResult: Decodable {
    let started: Bool
    /// When not started: "already", "off" or "outside_hours".
    let reason: String?
}

/// How last night and today compare with your usual numbers (docs/API.md, "Sleep and recovery").
struct Recovery: Decodable, Hashable {
    let level: String // "good", "normal" or "low"
    let summary: String
    let hrvMs: Double?
    let hrvUsualMs: Double?
    let restingHr: Int?
    let restingHrUsual: Int?
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
        case sleep(SleepNight, usualAsleepMin: Int?)
        case recovery(Recovery)
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
        case "sleep": content = .sleep(try c.decode(SleepNight.self, forKey: .sleep),
                                       usualAsleepMin: try c.decodeIfPresent(Int.self, forKey: .usualAsleepMin))
        case "recovery": content = .recovery(try Recovery(from: decoder))
        case "text": content = .text(try c.decode(String.self, forKey: .text))
        default: content = .unknown
        }
    }
    private enum CodingKeys: String, CodingKey { case type, title, events, items, reminders, habits, sleep, usualAsleepMin, text }
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

/// The wake-up briefing has no time: it runs when you get up.
struct WakeSchedule: Codable, Equatable { var enabled: Bool }

struct DigestSettings: Codable, Equatable {
    var daily: DigestSchedule // the morning digest
    var wake: WakeSchedule? // nil from older servers; left out when saving, so the server keeps its value
    var evening: DigestSchedule?
    var weekly: DigestSchedule
    var monthly: DigestSchedule
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
    var list: String?

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
        try c.encodeIfPresent(list, forKey: .list)
    }
    private enum CodingKeys: String, CodingKey { case id, appleId, title, notes, dueAt, completed, modifiedAt, deleted, list }
}

struct SyncRequest: Encodable {
    var cursor: String?
    var changes: [ReminderChange]
    /// Every Apple Reminders list on the phone, by name, and the one reminders without a list go to.
    var lists: [String] = []
    var defaultList: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(changes, forKey: .changes)
        try c.encode(lists, forKey: .lists)
        try c.encode(defaultList, forKey: .defaultList)
    }
    private enum CodingKeys: String, CodingKey { case cursor, changes, lists, defaultList }
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

// MARK: Course notebooks (docs/API.md, "Notebook")

/// A course's notebook (docs/API.md, "Notebook"). The course chat's progress bar only needs `writing`.
struct NotebookStatus: Decodable {
    var writing: NotebookProposal?
    var started: Bool?
    var busy: Bool?
    var exam: String?
    var introduction: String?
    var topics: [NotebookTopic]?
    var proposals: [NotebookProposal]?
}

struct NotebookProposal: Decodable, Hashable, Identifiable {
    let id: String
    var progress: NotebookProgress?
    var kind: String?
    var status: String?
    var items: [ProposalItem]?
    var material: [String]?
    var result: String?
}

struct ProposalItem: Decodable, Hashable, Identifiable {
    let n: Int
    var topic: String?
    let title: String
    var add: String?
    var sources: [String]?
    var id: Int { n }
}

struct NotebookProgress: Decodable, Hashable { let done: Int; let total: Int }

struct NotebookTopic: Decodable, Hashable, Identifiable {
    let id: String
    let position: Int
    let title: String
    var summary: String?
    var written: Bool?
    var questions: Int?
    var cards: Int?
    var edited: Bool?
}

/// A topic page, as `GET /v1/topics/{id}?plain=true`: maths as Unicode, links as text.
struct TopicPage: Decodable {
    let id: String
    let title: String
    var summary: String?
    var body: String?
    var cardsList: [Flashcard]?
    var sources: [String]?
}

struct Flashcard: Decodable, Hashable { let q: String; let a: String }

struct ProposalApplyBody: Encodable { var items: [Int]? }

// MARK: Practice exams (docs/API.md, "Practice exams")

/// What a course's practice exams can draw on, and the past ones.
struct QuizBank: Decodable {
    let course: Int
    var exam: String?
    var questions = 0
    var unseen = 0
    var toReview = 0
    var topics: [QuizBankTopic] = []
    var scoring: QuizScoring?
    var past: [Quiz] = []
}

struct QuizBankTopic: Decodable, Identifiable, Hashable { let id: String; let title: String; let questions: Int }
struct QuizScoring: Decodable { let right: Double; let wrong: Double }

struct Quiz: Decodable, Identifiable {
    let id: String
    let course: Int
    var minutes: Int?
    var count = 0
    var startedAt: String?
    var finishedAt: String?
    var score: QuizScore?
    var questions: [QuizQuestion] = []
}

struct QuizQuestion: Decodable, Identifiable {
    let n: Int
    let topic: QuizTopicRef
    let text: String
    let options: [QuizOption]
    // Once finished:
    var answer: String?
    var key: String?
    var correct: Bool?
    var explanation: String?
    var id: Int { n }
}

struct QuizTopicRef: Decodable, Hashable { let id: String; let title: String }
struct QuizOption: Decodable, Hashable { let letter: String; let text: String }

struct QuizScore: Decodable {
    let points: Double
    let max: Double
    let right: Int
    let wrong: Int
    let blank: Int
    var topics: [QuizTopicScore]?
}

struct QuizTopicScore: Decodable, Identifiable {
    let id: String
    let title: String
    let right: Int
    let wrong: Int
    let blank: Int
    var total: Int { right + wrong + blank }
}

struct QuizStartBody: Encodable { let course: Int; let count: Int; let minutes: Int? }
struct QuizFinishBody: Encodable { let answers: [String: String] }

// MARK: Moodle and the Obsidian vault (docs/API.md, "Moodle", "Obsidian vault")

struct MoodleStatus: Decodable {
    let enabled: Bool
    var site: String?
    var connected = false
    var user: String?
    var lastSync: String?
    var error: String?
    var courses: [MoodleCourse] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        user = try c.decodeIfPresent(String.self, forKey: .user)
        lastSync = try c.decodeIfPresent(String.self, forKey: .lastSync)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        courses = try c.decodeIfPresent([MoodleCourse].self, forKey: .courses) ?? []
    }
    private enum CodingKeys: String, CodingKey { case enabled, site, connected, user, lastSync, error, courses }
}

struct MoodleCourse: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// The Aide course it's synced into; nil: not synced.
    var course: Int?
    /// "auto" or "user"; nil before anything was matched.
    var matched: String?
    var files: Int?
}

/// Where the login starts, and the scheme its last address uses.
struct MoodleLogin: Decodable { let url: String; let scheme: String }
struct MoodleConnect: Encodable { let url: String }
/// `course` nil is sent as null: don't sync this one.
struct MoodleMatch: Encodable {
    let course: Int?
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(course, forKey: .course)
    }
    private enum CodingKeys: String, CodingKey { case course }
}

/// The courses from `GET /v1/study`, only what the Moodle screen needs.
struct StudyOverview: Decodable {
    let courses: [StudyCourse]
    var unfiled: Int?
    var now: StudyNow?
    var transcription: Bool?
}

struct StudyNow: Decodable, Hashable { let course: Int; let name: String; var ends: String? }

struct StudyCourse: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    var lectures: Int?
    var files: Int?
    var lastLecture: String?
    var nextExam: StudyExam?
    var chat: String?
    var notebook: CourseNotebook?

    /// "macroeconomics" as "Macroeconomics".
    var title: String { name.prefix(1).uppercased() + name.dropFirst() }
}

struct StudyExam: Decodable, Hashable { let date: String; let title: String }

/// A course's notebook in brief; nil when it has none.
struct CourseNotebook: Decodable, Hashable {
    let topics: Int
    var questions: Int?
    var proposals: Int?
    var writing: Bool?
}

struct Lecture: Decodable, Identifiable, Hashable {
    let id: String
    var course: Int?
    var title: String?
    var recordedAt: String?
    var durationS: Int?
    var hasAudio: Bool?
    let status: String
    var error: String?
    var summary: String?
    var notes: String?

    var isWorking: Bool { ["queued", "transcribing", "writing"].contains(status) }
}

struct LectureList: Decodable { let lectures: [Lecture] }

struct StudyFile: Decodable, Identifiable, Hashable {
    let id: String
    var course: Int?
    var lecture: String?
    let name: String
    var section: String?
    var size: Int?
    var pages: Int?
    var scanned: Bool?
    var source: String?
}

struct StudyFileList: Decodable { let files: [StudyFile] }
struct CourseChat: Decodable { let conversationId: String }

/// What Obsidian's Remotely Save plugin needs.
struct VaultSetup: Decodable {
    let enabled: Bool
    var url: String?
    var user: String?
    var password: String?
    var vault: String?
}
