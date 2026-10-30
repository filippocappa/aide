import Foundation

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case server(status: Int, message: String)
    case transport(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add the server URL and API token in Settings."
        case .unauthorized: "The server rejected the API token. Check it in Settings."
        case .server(let status, let message): status == 502 ? "\(message) (try again)" : message
        case .transport(let m): m
        case .badResponse: "The server sent something the app couldn't read."
        }
    }
}

/// Talks to docs/API.md. Reads its configuration on every call so Settings changes apply immediately.
@MainActor
final class APIClient {
    private let config: () -> APIConfig?
    private let session: URLSession
    /// Photos by id: what this app uploaded and what it fetched, so each is loaded once per launch.
    private var photos: [String: Data] = [:]
    /// Study PDFs and page images by path; dropped first under memory pressure.
    private let fileCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 150_000_000
        return cache
    }()

    init(session: URLSession = .shared, config: @escaping () -> APIConfig?) {
        self.session = session
        self.config = config
    }

    // MARK: Endpoints

    func health() async throws -> HealthResponse {
        try await send("GET", "/v1/health", auth: false)
    }

    /// A reply can take 5–30 s, so the timeout is generous.
    func chat(_ text: String, conversationID: String? = nil) async throws -> ChatReply {
        try await send("POST", "/v1/chat", body: ChatRequest(text: text, conversationId: conversationID), timeout: 120)
    }

    /// The chat, streamed: `onTeam` gets each message Aide and the agents send each other while Aide works,
    /// `onText` each piece of the reply as it's written, true when the draft starts over (docs/API.md, "Chat").
    /// A server without streaming answers plain JSON: same reply, nothing live. `photos` are uploaded ids.
    func chatLive(_ text: String, photos: [String] = [], conversationID: String? = nil, voice: Bool = false,
                  onText: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
                  onTeam: @escaping @MainActor (TeamMessage) -> Void) async throws -> ChatReply {
        let body = try JSONEncoder.api.encode(ChatRequest(text: text, conversationId: conversationID, stream: true,
                                                          photos: photos.isEmpty ? nil : photos,
                                                          voice: voice ? true : nil))
        return try await stream("/v1/chat", body: body, onEvent: { event in
            switch event {
            case .team(let message): onTeam(message)
            case .text(let delta, let restart): onText(delta, restart)
            default: break
            }
        }) { event in
            if case .reply(let reply) = event { return reply }
            return nil
        }
    }

    /// POSTs `body` asking for `text/event-stream`, hands each event to `onEvent` until `final` picks the last one.
    /// A server that answers plain JSON instead gets that decoded as the result.
    private func stream<T: Decodable>(_ path: String, body: Data, onEvent: @escaping @MainActor (EventStream.Event) -> Void,
                                      final: (EventStream.Event) -> T?) async throws -> T {
        var req = try request("POST", path, query: [], auth: true, timeout: 120, body: body)
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard (200..<300).contains(http.statusCode), type.hasPrefix("text/event-stream") else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                return try decode(data, http)
            }
            var stream = EventStream()
            for try await line in bytes.lines {
                guard let event = try stream.feed(line) else { continue }
                if let result = final(event) { return result }
                onEvent(event)
            }
            throw APIError.transport("The server stopped before answering.")
        } catch let error as URLError {
            throw APIError.transport(Self.describe(error))
        }
    }

    func team(limit: Int = 100) async throws -> [TeamMessage] {
        let list: TeamList = try await send("GET", "/v1/team", query: [URLQueryItem(name: "limit", value: String(limit))])
        return list.messages
    }

    /// Writes in the Team chat, streamed: `onEvent` gets each agent starting to write and each new message.
    func postTeam(_ text: String, onEvent: @escaping @MainActor (EventStream.Event) -> Void) async throws -> TeamReply {
        let body = try JSONEncoder.api.encode(TeamPost(text: text, stream: true))
        return try await stream("/v1/team", body: body, onEvent: onEvent) { event in
            if case .done(let reply) = event { return reply }
            return nil
        }
    }

    func routines(agent: String? = nil) async throws -> [Routine] {
        let query = agent.map { [URLQueryItem(name: "agent", value: $0)] } ?? []
        let list: RoutineList = try await send("GET", "/v1/routines", query: query)
        return list.routines
    }

    func createRoutine(_ draft: RoutineDraft) async throws -> Routine {
        try await send("POST", "/v1/routines", body: draft)
    }

    func updateRoutine(_ id: Int, _ draft: RoutineDraft) async throws -> Routine {
        try await send("PATCH", "/v1/routines/\(id)", body: draft)
    }

    func deleteRoutine(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/routines/\(id)", body: EmptyBody())
    }

    /// Runs it now and returns once its message is posted, which can take 30 s.
    func runRoutine(_ id: Int) async throws -> RoutineRun {
        try await send("POST", "/v1/routines/\(id)/run", body: EmptyBody(), timeout: 120)
    }

    func confirm() async throws -> ActionResult {
        try await send("POST", "/v1/confirm", body: EmptyBody(), timeout: 120)
    }

    func cancel() async throws -> ActionResult {
        try await send("POST", "/v1/cancel", body: EmptyBody())
    }

    /// Only these queued actions; the rest keep waiting.
    func confirm(ids: [Int]) async throws -> ActionResult {
        try await send("POST", "/v1/confirm", body: ActionIDs(ids: ids), timeout: 120)
    }

    func cancel(ids: [Int]) async throws -> ActionResult {
        try await send("POST", "/v1/cancel", body: ActionIDs(ids: ids))
    }

    // MARK: Activity and approvals

    /// `kinds`: only those kinds of line (e.g. the team's notes, `["routine", "watch"]`).
    func activity(agent: String? = nil, kinds: [String] = [], before: Int? = nil,
                  limit: Int = 100) async throws -> ActivityPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        if !kinds.isEmpty { query.append(URLQueryItem(name: "kind", value: kinds.joined(separator: ","))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await send("GET", "/v1/activity", query: query)
    }

    func approvals() async throws -> Approvals {
        try await send("GET", "/v1/approvals")
    }

    // MARK: Mail drafts

    /// Sends it at once: the tap is the confirmation. `body` is the edited text, or nil as drafted.
    func sendDraft(_ id: Int, body: String?) async throws -> MailDraft {
        let sent: DraftSent = try await send("POST", "/v1/mail/drafts/\(id)/send", body: DraftBody(body: body), timeout: 60)
        return sent.draft
    }

    func dismissDraft(_ id: Int) async throws {
        let _: OKResponse = try await send("POST", "/v1/mail/drafts/\(id)/dismiss", body: EmptyBody())
    }

    func think(conversationID: String? = nil) async throws {
        let _: OKResponse = try await send("POST", "/v1/think", body: ConversationBody(conversationId: conversationID))
    }

    func history(limit: Int = 50, conversationID: String? = nil) async throws -> HistoryResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let conversationID { query.append(URLQueryItem(name: "conversation_id", value: conversationID)) }
        return try await send("GET", "/v1/history", query: query)
    }

    func conversations() async throws -> [Conversation] {
        let list: ConversationList = try await send("GET", "/v1/conversations")
        return list.conversations
    }

    /// With a digest kind the chat opens with that digest's greeting. The server may have to make the
    /// digest first, which can take 30 s.
    func createConversation(digest: String? = nil, agent: String? = nil) async throws -> Conversation {
        try await send("POST", "/v1/conversations", body: NewConversation(digest: digest, agent: agent), timeout: 60)
    }

    func agents() async throws -> [Agent] {
        let list: AgentList = try await send("GET", "/v1/agents")
        return list.agents
    }

    /// Speech to text on the server (docs/API.md, "Voice"): a WAV recording in, what was said out.
    func transcribe(wav: Data, language: String) async throws -> String {
        var req = try request("POST", "/v1/transcribe", query: [URLQueryItem(name: "language", value: language)],
                              auth: true, timeout: 30, body: nil)
        req.httpBody = wav
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let reply: Transcript = try await perform(req)
        return reply.text
    }

    /// Uploads a JPEG (docs/API.md, "Photos") and returns its id. It's kept here too, so it shows without a download.
    func uploadPhoto(_ jpeg: Data) async throws -> String {
        var req = try request("POST", "/v1/photos", query: [], auth: true, timeout: 60, body: nil)
        req.httpBody = jpeg
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let reply: PhotoUpload = try await perform(req)
        photos[reply.id] = jpeg
        return reply.id
    }

    /// A photo's bytes, from memory after the first time.
    func photo(_ id: String) async throws -> Data {
        if let data = photos[id] { return data }
        var req = try request("GET", "/v1/photos/\(id)", query: [], auth: true, timeout: 30, body: nil)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, http) = try await fetch(req)
        try check(data, http)
        photos[id] = data
        return data
    }

    func deleteConversation(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/conversations/\(id)", body: EmptyBody())
    }

    func memory() async throws -> [MemoryItem] {
        let list: MemoryList = try await send("GET", "/v1/memory")
        return list.items
    }

    func addMemory(_ text: String, agent: String? = nil) async throws -> MemoryItem {
        try await send("POST", "/v1/memory", body: MemoryRequest(text: text, agent: agent))
    }

    func deleteMemory(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/memory/\(id)", body: EmptyBody())
    }

    func sendLocation(_ fix: LocationFix) async throws {
        let _: OKResponse = try await send("POST", "/v1/location", body: fix)
    }

    /// A departures card again, from its own stop, line and destination.
    func departures(_ board: DepartureBoard) async throws -> DepartureBoard {
        var query = [URLQueryItem(name: "stop", value: board.stop.id)]
        if let line = board.line { query.append(URLQueryItem(name: "line", value: line)) }
        if let to = board.to {
            query.append(URLQueryItem(name: "to", value: to.stops.joined(separator: ",")))
            query.append(URLQueryItem(name: "to_name", value: to.name))
        }
        return try await send("GET", "/v1/transit/departures", query: query)
    }

    func transitAlerts() async throws -> [TransitAlert] {
        let list: TransitAlertList = try await send("GET", "/v1/transit/alerts")
        return list.alerts
    }

    func updateTransitAlert(_ id: Int, _ patch: TransitAlertPatch) async throws -> TransitAlert {
        try await send("PATCH", "/v1/transit/alerts/\(id)", body: patch)
    }

    func deleteTransitAlert(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/transit/alerts/\(id)", body: EmptyBody())
    }

    // MARK: Screen Time (docs/API.md, "Screen Time")

    func locks() async throws -> LockList {
        try await send("GET", "/v1/locks")
    }

    func createLock(_ lock: NewLock) async throws -> ScreenLock {
        try await send("POST", "/v1/locks", body: lock)
    }

    func updateLock(_ id: Int, _ patch: LockPatch) async throws -> ScreenLock {
        try await send("PATCH", "/v1/locks/\(id)", body: patch)
    }

    /// Ends a lock that's on now, early. The schedule it stays, or nil: a one-off, now gone.
    func unlock(_ id: Int, reason: String, pass: Bool = false) async throws -> ScreenLock? {
        let answer: Unlocked = try await send("POST", "/v1/locks/\(id)/unlock",
                                              body: UnlockReason(reason: reason, pass: pass ? true : nil))
        return answer.lock
    }

    func deleteLock(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/locks/\(id)", body: EmptyBody())
    }

    func reportScreenTime(_ device: ScreenTimeDevice) async throws {
        let _: ScreenTimeDevice = try await send("PUT", "/v1/locks/device", body: device)
    }

    // MARK: Browser errands (docs/API.md, "Browser errands")

    func errands(open: Bool = false, limit: Int = 30) async throws -> ErrandList {
        try await send("GET", "/v1/errands", query: [URLQueryItem(name: "open", value: open ? "true" : "false"),
                                                    URLQueryItem(name: "limit", value: String(limit))])
    }

    func errand(_ id: Int) async throws -> Errand {
        try await send("GET", "/v1/errands/\(id)")
    }

    /// You did your part in the live view: it goes on.
    func errandDone(_ id: Int) async throws -> Errand {
        try await send("POST", "/v1/errands/\(id)/done", body: EmptyBody())
    }

    func replyErrand(_ id: Int, answer: String) async throws -> Errand {
        try await send("POST", "/v1/errands/\(id)/reply", body: ErrandAnswer(answer: answer))
    }

    func cancelErrand(_ id: Int) async throws -> Errand {
        try await send("POST", "/v1/errands/\(id)/cancel", body: EmptyBody())
    }

    /// The errand's page as it is now (JPEG), or nil when none is open.
    func errandFrame(_ id: Int) async throws -> Data? {
        let req = try request("GET", "/v1/errands/\(id)/frame", query: [], auth: true, timeout: 20, body: nil)
        let (data, http) = try await fetch(req)
        if http.statusCode == 404 { return nil }
        try check(data, http)
        return data
    }

    func browserSites() async throws -> BrowserSites {
        try await send("GET", "/v1/browser/sites")
    }

    /// Opens a site in Aide's browser to log in there (then the live view with `site`).
    func openSite(_ url: String) async throws -> OpenedSite {
        try await send("POST", "/v1/browser/sites", body: SiteToOpen(url: url), timeout: 45)
    }

    func forgetSite(_ site: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/browser/sites/\(site)", body: EmptyBody())
    }

    func purchases(days: Int? = nil) async throws -> PurchaseList {
        try await send("GET", "/v1/purchases", query: days.map { [URLQueryItem(name: "days", value: String($0))] } ?? [])
    }

    /// The live view's socket: an errand's page, or a site to log in to. The token goes in the header, as for
    /// every other call.
    /// `frames` false: no frames until `frames(on:)`, for the app's own drawing of the page (its `scene`).
    func browserLiveRequest(errand: Int? = nil, site: String? = nil, frames: Bool = true) throws -> URLRequest {
        var query = errand.map { [URLQueryItem(name: "errand", value: String($0))] }
            ?? [URLQueryItem(name: "site", value: site ?? "")]
        if !frames { query.append(URLQueryItem(name: "frames", value: "false")) }
        var req = try request("GET", "/v1/browser/live", query: query, auth: true, timeout: 30, body: nil)
        guard let url = req.url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.notConfigured
        }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        req.url = comps.url
        return req
    }

    func transitSettings() async throws -> TransitSettings {
        try await send("GET", "/v1/transit/settings")
    }

    func updateTransitSettings(_ settings: TransitSettings) async throws -> TransitSettings {
        try await send("PATCH", "/v1/transit/settings", body: settings)
    }

    func digest(kind: String) async throws -> Digest {
        try await send("GET", "/v1/digest", query: [URLQueryItem(name: "kind", value: kind)])
    }

    /// A digest written again now (5–30 s). Not pushed; a wake-up one doesn't count as the day's wake-up.
    func runDigest(kind: String) async throws -> Digest {
        try await send("POST", "/v1/digest/run", body: ["kind": kind], timeout: 90)
    }

    func digestSettings() async throws -> DigestSettings {
        try await send("GET", "/v1/digest/settings")
    }

    func saveDigestSettings(_ settings: DigestSettings) async throws -> DigestSettings {
        try await send("PUT", "/v1/digest/settings", body: settings)
    }

    func habits() async throws -> [Habit] {
        let list: HabitList = try await send("GET", "/v1/habits")
        return list.habits
    }

    func addHabit(_ habit: HabitNew) async throws -> Habit {
        try await send("POST", "/v1/habits", body: habit)
    }

    func deleteHabit(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/habits/\(id)", body: EmptyBody())
    }

    // MARK: Objectives

    func objectives() async throws -> ObjectivesOverview {
        try await send("GET", "/v1/objectives")
    }

    func addObjective(_ new: NewObjective) async throws -> Objective {
        try await send("POST", "/v1/objectives", body: new)
    }

    func updateObjective(_ id: String, _ patch: ObjectivePatch) async throws -> Objective {
        try await send("PATCH", "/v1/objectives/\(id)", body: patch)
    }

    /// Ticks or unticks one by hand. One tied to a reminder completes the reminder instead, which ticks it (and
    /// reaches Apple Reminders); a reminder deleted since falls back to the plain tick.
    func tickObjective(_ objective: Objective) async throws -> Objective {
        if let reminder = objective.reminderID {
            do {
                _ = try await completeReminder(reminder, completed: !objective.done)
                return try await objectives()[objective.period].objectives.first { $0.id == objective.id } ?? objective
            } catch APIError.server(404, _) {}
        }
        return try await updateObjective(objective.id, ObjectivePatch(done: !objective.done))
    }

    /// `ids` nil: all of that period's proposals. `date` is any day in the period.
    func acceptObjectives(period: String, date: String, ids: [String]? = nil) async throws -> ObjectiveBlock {
        try await send("POST", "/v1/objectives/accept", body: ObjectivesAccept(period: period, date: date, ids: ids))
    }

    /// Proposes now (one model call, can take 30 s).
    func planObjectives(period: String, date: String) async throws -> ObjectiveBlock {
        try await send("POST", "/v1/objectives/plan", body: ObjectivesPlan(period: period, date: date), timeout: 120)
    }

    func checkHabit(_ id: Int, done: Bool) async throws -> Habit {
        try await send("POST", "/v1/habits/\(id)/check", body: HabitCheck(done: done))
    }

    /// A limit habit: one more today (`add` 1), or one taken back (-1).
    func countHabit(_ id: Int, add: Int = 1) async throws -> Habit {
        try await send("POST", "/v1/habits/\(id)/count", body: HabitCount(add: add))
    }

    func updateHabit(_ id: Int, _ habit: HabitNew) async throws -> Habit {
        try await send("PATCH", "/v1/habits/\(id)", body: habit)
    }

    func food(date: Date? = nil) async throws -> FoodDay {
        let query = date.map { [URLQueryItem(name: "date", value: Wire.dayString($0))] } ?? []
        return try await send("GET", "/v1/food", query: query)
    }

    /// Oldest first, every day in the range.
    func foodDays(from: Date, to: Date) async throws -> [FoodDaySummary] {
        let list: FoodDayList = try await send("GET", "/v1/food/days", query: [
            URLQueryItem(name: "from", value: Wire.dayString(from)), URLQueryItem(name: "to", value: Wire.dayString(to)),
        ])
        return list.days
    }

    /// Coach looks at the photos and logs the meal, which can take 30 s.
    func logFood(_ request: FoodLogRequest) async throws -> FoodLogReply {
        try await send("POST", "/v1/food/log", body: request, timeout: 120)
    }

    /// Every meal from `from` to `to` (local days, at most 92), oldest first: what the app writes to Apple Health.
    func meals(from: Date, to: Date) async throws -> [Meal] {
        let list: MealList = try await send("GET", "/v1/food/meals", query: [
            URLQueryItem(name: "from", value: Wire.dayString(from)), URLQueryItem(name: "to", value: Wire.dayString(to)),
        ])
        return list.meals
    }

    /// A scanned barcode: the saved food, else Open Food Facts' product (saved on the way); nil when neither has it.
    func food(barcode: String) async throws -> SavedFood? {
        let found: FoodLookup = try await send("GET", "/v1/food/barcode/\(barcode)", timeout: 30)
        return found.food
    }

    /// Reads the nutrition label in an uploaded photo (one model call, up to ~30 s) and saves it for the barcode.
    func readLabel(_ request: LabelRequest) async throws -> SavedFood {
        let found: FoodLookup = try await send("POST", "/v1/food/label", body: request, timeout: 120)
        guard let food = found.food else { throw APIError.badResponse }
        return food
    }

    /// Logs a saved food as a meal; the server adds it up, no model call.
    func logFood(_ id: Int, _ portion: FoodPortion) async throws -> Meal {
        let logged: LoggedMeal = try await send("POST", "/v1/food/foods/\(id)/log", body: portion)
        return logged.meal
    }

    func updateMeal(_ id: Int, _ changes: MealChanges) async throws -> Meal {
        try await send("PATCH", "/v1/food/meals/\(id)", body: changes)
    }

    func deleteMeal(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/food/meals/\(id)", body: EmptyBody())
    }

    func foodGoals() async throws -> FoodGoals {
        try await send("GET", "/v1/food/goals")
    }

    func saveFoodGoals(_ goals: FoodGoals) async throws -> FoodGoals {
        try await send("PUT", "/v1/food/goals", body: goals)
    }

    func foodTargets() async throws -> FoodTargets {
        try await send("GET", "/v1/food/targets")
    }

    func saveFoodTargets(_ targets: FoodTargets) async throws -> FoodTargets {
        try await send("PUT", "/v1/food/targets", body: targets)
    }

    /// Coach's proposal from the profile, Apple Health and the food log: one model call, up to ~30 s.
    func proposeFoodTargets(answers: [TargetsAnswers.Answer] = []) async throws -> TargetsProposal {
        try await send("POST", "/v1/food/targets/propose", body: TargetsAnswers(answers: answers), timeout: 120)
    }

    func uploadHealthDays(_ days: [HealthDay]) async throws -> HealthUploadResult {
        try await send("POST", "/v1/health/days", body: HealthUpload(days: days), timeout: 60)
    }

    /// The last 30 days the server has, newest first.
    /// Newest first; the last 30 days, or since `from`.
    func healthDays(from: Date? = nil) async throws -> [HealthDayReading] {
        let query = from.map { [URLQueryItem(name: "from", value: Wire.dayString($0))] } ?? []
        let list: HealthDayList = try await send("GET", "/v1/health/days", query: query)
        return list.days
    }

    /// Sleep, Recovery and Strain for a day (today by default), with what they're made of.
    func healthScores(date: Date? = nil) async throws -> HealthScores {
        let query = date.map { [URLQueryItem(name: "date", value: Wire.dayString($0))] } ?? []
        return try await send("GET", "/v1/health/scores", query: query)
    }

    /// The three scores for each of `days` days up to `to`, newest first.
    func healthScoreHistory(days: Int = 30, to: Date? = nil) async throws -> [ScoreDay] {
        var query = [URLQueryItem(name: "days", value: String(days))]
        if let to { query.append(URLQueryItem(name: "to", value: Wire.dayString(to))) }
        let history: ScoreHistory = try await send("GET", "/v1/health/scores/history", query: query)
        return history.days
    }

    /// Coach's take on one of the day's scores (`sleep`, `recovery`, `strain`): one model call, so it can take a while.
    func healthInsight(kind: String, date: Date) async throws -> HealthInsight {
        try await send("POST", "/v1/health/insight",
                       body: HealthInsightRequest(kind: kind, date: Wire.dayString(date)), timeout: 120)
    }

    /// The weight readings for `days` days back, the trend, and what was logged through Aide (docs/API.md, Weight).
    func weight(days: Int = 90) async throws -> WeightList {
        try await send("GET", "/v1/health/weight", query: [URLQueryItem(name: "days", value: String(days))])
    }

    func logWeight(_ kg: Double) async throws -> WeightLogged {
        try await send("POST", "/v1/health/weight", body: WeightIn(kg: kg))
    }

    func deleteWeight(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/health/weight/\(id)", body: EmptyBody())
    }

    func wake(_ request: WakeRequest) async throws -> WakeResult {
        try await send("POST", "/v1/wake", body: request)
    }

    func today(date: Date? = nil) async throws -> TodayResponse {
        let query = date.map { [URLQueryItem(name: "date", value: Wire.dayString($0))] } ?? []
        return try await send("GET", "/v1/today", query: query)
    }

    /// Every calendar's events for `days` days from a local day (docs/API.md, "Events and plans").
    func events(from day: Date, days: Int = 7) async throws -> [CalendarEvent] {
        let list: EventsResponse = try await send("GET", "/v1/events", query: [
            URLQueryItem(name: "from", value: Wire.dayString(day)), URLQueryItem(name: "days", value: String(days)),
        ])
        return list.events
    }

    /// The user's own move: date-times, or for an all-day event its first and last day.
    func moveEvent(_ id: String, start: String, end: String) async throws -> CalendarEvent {
        try await send("PATCH", "/v1/events/\(id)", body: EventMoveBody(start: start, end: end))
    }

    func deleteEvent(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/events/\(id)", body: EmptyBody())
    }

    /// A plan's items into the calendar (the tap is the confirmation); `items` nil: all still proposed.
    func addPlan(_ plan: String, items: [String]?) async throws -> [CalendarEvent] {
        let r: EventsResponse = try await send("POST", "/v1/plans/\(plan)/add", body: PlanItemsBody(items: items))
        return r.events
    }

    func dropPlan(_ plan: String, items: [String]?) async throws -> [CalendarEvent] {
        let r: EventsResponse = try await send("POST", "/v1/plans/\(plan)/drop", body: PlanItemsBody(items: items))
        return r.events
    }

    func syncReminders(cursor: String?, changes: [ReminderChange], lists: [String] = [],
                       defaultList: String? = nil) async throws -> SyncResponse {
        try await send("POST", "/v1/reminders/sync",
                       body: SyncRequest(cursor: cursor, changes: changes, lists: lists, defaultList: defaultList), timeout: 60)
    }

    func registerDevice(_ device: DeviceRegistration) async throws {
        let _: OKResponse = try await send("POST", "/v1/devices", body: device)
    }

    func testPush() async throws -> PushTestResult {
        try await send("POST", "/v1/devices/test", body: EmptyBody())
    }

    // MARK: Widgets and Live Activities (docs/API.md)

    /// The Today widget's tick box: the server marks it and the next sync ticks it in Apple Reminders.
    func completeReminder(_ id: String, completed: Bool = true) async throws -> Reminder {
        try await send("POST", "/v1/reminders/\(id)/complete", body: ReminderCompletion(completed: completed))
    }

    /// Boards for the stops nearest the phone's last fix.
    func nearbyDepartures() async throws -> NearbyBoards {
        try await send("GET", "/v1/transit/nearby")
    }

    func liveSettings() async throws -> LiveSettings {
        try await send("GET", "/v1/live/settings")
    }

    func updateLiveSettings(_ settings: LiveSettings) async throws -> LiveSettings {
        try await send("PATCH", "/v1/live/settings", body: settings)
    }

    /// A push-to-start token for one kind of Live Activity (`tram`, `agent`, `event`).
    func registerLiveToken(kind: String, token: String, environment: String) async throws {
        let _: OKResponse = try await send("POST", "/v1/live/tokens",
                                           body: LiveToken(kind: kind, token: token, environment: environment))
    }

    func deleteLiveToken(kind: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/live/tokens/\(kind)")
    }

    /// One activity's update token, by the key in its attributes.
    func registerLiveActivity(key: String, token: String, environment: String) async throws {
        let _: OKResponse = try await send("POST", "/v1/live/activities",
                                           body: LiveActivityToken(key: key, token: token, environment: environment))
    }

    func deleteLiveActivity(key: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/live/activities/\(key)") // URLComponents escapes it
    }

    /// A GET's body as it came, after the status check: the widgets keep it to draw from when the server is away.
    func raw(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let (data, http) = try await fetch(try request("GET", path, query: query, auth: true, timeout: 20, body: nil))
        try check(data, http)
        return data
    }

    func moodle() async throws -> MoodleStatus {
        try await send("GET", "/v1/moodle")
    }

    func moodleLogin() async throws -> MoodleLogin {
        try await send("POST", "/v1/moodle/login", body: EmptyBody())
    }

    /// The address the login ended on; the server checks it and keeps the token. It also syncs, so it can be slow.
    func moodleConnect(_ url: String) async throws -> MoodleStatus {
        try await send("POST", "/v1/moodle/connect", body: MoodleConnect(url: url), timeout: 60)
    }

    func moodleLogout() async throws -> MoodleStatus {
        try await send("DELETE", "/v1/moodle", body: EmptyBody())
    }

    /// Starts a sync in the background; `lastSync` changes when it's done.
    func moodleSync() async throws -> MoodleStatus {
        try await send("POST", "/v1/moodle/sync", body: EmptyBody())
    }

    func matchMoodleCourse(_ id: Int, course: Int?) async throws -> MoodleCourse {
        try await send("PATCH", "/v1/moodle/courses/\(id)", body: MoodleMatch(course: course))
    }

    func study() async throws -> StudyOverview {
        try await send("GET", "/v1/study")
    }

    func notebook(course: Int) async throws -> NotebookStatus {
        try await send("GET", "/v1/notebook", query: [URLQueryItem(name: "course", value: String(course))])
    }

    // MARK: Study (docs/API.md, "Study", "Study files", "Notebook")

    /// Notes as the app shows them: the maths as LaTeX (`MathFormula` on its own lines, `MathText` in sentences).
    private static let readable = ["plain", "latex", "inline"].map { URLQueryItem(name: $0, value: "true") }

    /// The notebook as the Study tab shows it: inline maths as Unicode, formulas on their own lines as LaTeX, links as text.
    func notebookPage(course: Int) async throws -> NotebookStatus {
        try await send("GET", "/v1/notebook", query: [URLQueryItem(name: "course", value: String(course))] + Self.readable)
    }

    func startNotebook(course: Int) async throws -> NotebookStatus {
        try await send("POST", "/v1/notebook", query: [URLQueryItem(name: "course", value: String(course))],
                       body: EmptyBody())
    }

    /// The formula sheet, as markdown.
    func formulas(course: Int) async throws -> String {
        let sheet: FormulaSheet = try await send("GET", "/v1/notebook/formulas",
                                                 query: [URLQueryItem(name: "course", value: String(course))] + Self.readable)
        return sheet.body
    }

    func exerciseSets(course: Int) async throws -> [ExerciseSet] {
        let list: ExerciseSetList = try await send("GET", "/v1/notebook/exercises",
                                                   query: [URLQueryItem(name: "course", value: String(course))])
        return list.sets
    }

    /// A topic's exercises, as markdown with the solutions folded.
    func exercises(_ id: String) async throws -> String {
        let set: ExerciseSet = try await send("GET", "/v1/exercises/\(id)",
                                              query: Self.readable)
        return set.body ?? ""
    }

    /// Exercises for the topics given, or every written one; Professor writes them in the background.
    func writeExercises(course: Int, topics: [String]? = nil) async throws -> NotebookStatus {
        try await send("POST", "/v1/notebook/exercises", query: [URLQueryItem(name: "course", value: String(course))],
                       body: ExercisesBody(topics: topics))
    }

    func topic(_ id: String) async throws -> TopicPage {
        try await send("GET", "/v1/topics/\(id)", query: Self.readable)
    }

    /// `items` nil: all of them.
    func applyProposal(_ id: String, items: [Int]?) async throws -> NotebookProposal {
        try await send("POST", "/v1/proposals/\(id)/apply", body: ProposalApplyBody(items: items))
    }

    func declineProposal(_ id: String) async throws -> NotebookProposal {
        try await send("POST", "/v1/proposals/\(id)/decline", body: EmptyBody())
    }

    /// Who writes the notes: the user's Claude plan or OpenRouter (docs/API.md, "Who writes the notes").
    func notesWriter() async throws -> NotesWriter {
        try await send("GET", "/v1/writer")
    }

    func setNotesWriter(_ engine: String) async throws -> NotesWriter {
        try await send("PUT", "/v1/writer", body: WriterChoice(engine: engine))
    }

    /// Routines, watches, digests, drafts and chat titles: "claude" or "openrouter".
    func setBackgroundWorker(_ engine: String) async throws -> NotesWriter {
        try await send("PUT", "/v1/writer", body: WriterChoice(background: engine))
    }

    /// The answer to a job paused on the plan's limit: "wait" or "openrouter".
    func decideWriter(_ use: String) async throws -> NotesWriter {
        try await send("POST", "/v1/writer/decide", body: WriterDecision(use: use))
    }

    func findFigures(course: Int) async throws -> NotebookStatus {
        try await send("POST", "/v1/notebook/figures", query: [URLQueryItem(name: "course", value: String(course))],
                       body: EmptyBody())
    }

    func lectures(course: Int) async throws -> [Lecture] {
        let list: LectureList = try await send("GET", "/v1/lectures",
                                               query: [URLQueryItem(name: "course", value: String(course))])
        return list.lectures
    }

    func lecture(_ id: String) async throws -> Lecture {
        try await send("GET", "/v1/lectures/\(id)", query: Self.readable)
    }

    func file(_ id: String) async throws -> StudyFile {
        try await send("GET", "/v1/files/\(id)")
    }

    func files(course: Int) async throws -> [StudyFile] {
        let list: StudyFileList = try await send("GET", "/v1/files",
                                                 query: [URLQueryItem(name: "course", value: String(course))])
        return list.files
    }

    func courseChat(_ course: Int) async throws -> String {
        let chat: CourseChat = try await send("POST", "/v1/study/courses/\(course)/chat", body: EmptyBody())
        return chat.conversationId
    }

    /// A file's PDF, or one page of it drawn as a JPEG (a figure in the notes), kept in memory once fetched.
    func fileData(_ id: String, page: Int? = nil) async throws -> Data {
        let path = page.map { "/v1/files/\(id)/pages/\($0)" } ?? "/v1/files/\(id)/pdf"
        if let data = fileCache.object(forKey: path as NSString) { return data as Data }
        var req = try request("GET", path, query: [], auth: true, timeout: 120, body: nil)
        req.setValue(page == nil ? "application/pdf" : "image/jpeg", forHTTPHeaderField: "Accept")
        let (data, http) = try await fetch(req)
        try check(data, http)
        fileCache.setObject(data as NSData, forKey: path as NSString, cost: data.count)
        return data
    }

    /// A PDF from Files into the course's material.
    func uploadPDF(_ file: URL, name: String, course: Int) async throws -> StudyFile {
        var req = try request("POST", "/v1/files", query: [URLQueryItem(name: "course", value: String(course)),
                                                           URLQueryItem(name: "name", value: name)],
                              auth: true, timeout: 600, body: nil)
        req.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        return try await upload(req, file)
    }

    /// A lecture recording from Files: transcribed and written up on the server.
    func uploadRecording(_ file: URL, type: String, course: Int, recordedAt: Date) async throws -> Lecture {
        let when = ISO8601DateFormatter().string(from: recordedAt) // UTC, with Z
        var req = try request("POST", "/v1/lectures", query: [URLQueryItem(name: "course", value: String(course)),
                                                              URLQueryItem(name: "recorded_at", value: when)],
                              auth: true, timeout: 1800, body: nil)
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        return try await upload(req, file)
    }

    /// Sends a file as the raw body, from disk: a recording can be hundreds of MB.
    private func upload<T: Decodable>(_ req: URLRequest, _ file: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: req, fromFile: file)
        } catch let error as URLError {
            throw APIError.transport(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        return try decode(data, http)
    }

    /// Review sessions not yet over, soonest first.
    func reviewSessions(course: Int) async throws -> [ReviewSession] {
        let list: ReviewSessionList = try await send("GET", "/v1/reviews",
                                                     query: [URLQueryItem(name: "course", value: String(course))])
        return list.sessions
    }

    /// Takes it off the calendar.
    func cancelReviewSession(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/reviews/\(id)", body: EmptyBody())
    }

    func quizBank(course: Int) async throws -> QuizBank {
        try await send("GET", "/v1/quizzes", query: [URLQueryItem(name: "course", value: String(course))])
    }

    func startQuiz(course: Int, count: Int, minutes: Int?) async throws -> Quiz {
        try await send("POST", "/v1/quizzes", body: QuizStartBody(course: course, count: count, minutes: minutes))
    }

    /// A mock exam, with its own time and scoring.
    func startMock(course: Int, mock: String) async throws -> Quiz {
        try await send("POST", "/v1/quizzes", body: QuizStartBody(course: course, mock: mock))
    }

    func quiz(_ id: String) async throws -> Quiz {
        try await send("GET", "/v1/quizzes/\(id)")
    }

    func mocks(course: Int) async throws -> [MockExam] {
        let list: MockExamList = try await send("GET", "/v1/notebook/mocks",
                                                query: [URLQueryItem(name: "course", value: String(course))])
        return list.mocks
    }

    /// Professor writes one like the real exam, in the background.
    func writeMock(course: Int) async throws -> NotebookStatus {
        try await send("POST", "/v1/notebook/mocks", query: [URLQueryItem(name: "course", value: String(course))],
                       body: EmptyBody())
    }

    /// Answers by question number; a question left out is blank.
    func finishQuiz(_ id: String, answers: [Int: QuizAnswer]) async throws -> Quiz {
        let body = QuizFinishBody(answers: Dictionary(uniqueKeysWithValues: answers.map { (String($0.key), $0.value) }))
        return try await send("POST", "/v1/quizzes/\(id)/finish", body: body)
    }

    func vault() async throws -> VaultSetup {
        try await send("GET", "/v1/vault")
    }

    private struct EventMoveBody: Encodable { let start: String; let end: String }
    private struct PlanItemsBody: Encodable { let items: [String]? }

    // MARK: Plumbing

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], auth: Bool = true, timeout: TimeInterval = 30
    ) async throws -> T {
        try await perform(try request(method, path, query: query, auth: auth, timeout: timeout, body: nil))
    }

    private func send<B: Encodable, T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: B, timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try JSONEncoder.api.encode(body)
        return try await perform(try request(method, path, query: query, auth: true, timeout: timeout, body: data))
    }

    private func request(
        _ method: String, _ path: String, query: [URLQueryItem], auth: Bool, timeout: TimeInterval, body: Data?
    ) throws -> URLRequest {
        guard let cfg = config() else { throw APIError.notConfigured }
        var comps = URLComponents(url: cfg.baseURL, resolvingAgainstBaseURL: false)
        let basePath = comps?.path.trimmingSuffix("/") ?? ""
        comps?.path = basePath + path
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else { throw APIError.notConfigured }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth { req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, http) = try await fetch(req)
        return try decode(data, http)
    }

    private func fetch(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw APIError.transport(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        return (data, http)
    }

    /// Throws the server's error for a status outside 2xx.
    private func check(_ data: Data, _ http: HTTPURLResponse) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            ?? "Server error (\(http.statusCode))."
        throw APIError.server(status: http.statusCode, message: message)
    }

    private func decode<T: Decodable>(_ data: Data, _ http: HTTPURLResponse) throws -> T {
        try check(data, http)
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw APIError.badResponse
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "The server took too long to answer."
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            "Can't reach the server. Is Tailscale on?"
        default: error.localizedDescription
        }
    }
}

private struct ErrorBody: Decodable { let error: String }
private struct Transcript: Decodable { let text: String }

/// Reads a streamed chat (`text/event-stream`) line by line. Each event has one `data:` line of JSON, handled
/// as soon as it arrives: the line reader drops the blank lines that end an event.
struct EventStream {
    enum Event {
        case team(TeamMessage), text(delta: String, restart: Bool), reply(ChatReply), working(agent: String), done(TeamReply)
    }
    private struct Working: Decodable { let agent: String }
    private struct Text: Decodable { let delta: String; var restart: Bool? }
    private var name = "message"

    mutating func feed(_ line: String) throws -> Event? {
        if line.hasPrefix("event:") {
            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil } // comments (":"), ids, retry
        let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        defer { name = "message" }
        do {
            switch name {
            case "team": return .team(try JSONDecoder.api.decode(TeamMessage.self, from: data))
            case "reply": return .reply(try JSONDecoder.api.decode(ChatReply.self, from: data))
            case "text":
                let text = try JSONDecoder.api.decode(Text.self, from: data)
                return .text(delta: text.delta, restart: text.restart ?? false)
            case "working": return .working(agent: try JSONDecoder.api.decode(Working.self, from: data).agent)
            case "done": return .done(try JSONDecoder.api.decode(TeamReply.self, from: data))
            case "error":
                let message = (try? JSONDecoder.api.decode(StreamError.self, from: data))?.error ?? "Something went wrong."
                throw APIError.server(status: 500, message: message)
            default: return nil
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.badResponse
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
