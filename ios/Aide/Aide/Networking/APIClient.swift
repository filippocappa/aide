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

    /// The chat, streamed: `onTeam` gets each message Aide and the agents send each other while Aide works
    /// (docs/API.md, "Chat"). A server without streaming answers plain JSON: same reply, nothing live.
    func chatLive(_ text: String, conversationID: String? = nil,
                  onTeam: @escaping @MainActor (TeamMessage) -> Void) async throws -> ChatReply {
        let body = try JSONEncoder.api.encode(ChatRequest(text: text, conversationId: conversationID, stream: true))
        return try await stream("/v1/chat", body: body, onEvent: { if case .team(let message) = $0 { onTeam(message) } }) { event in
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

    func digest(kind: String) async throws -> Digest {
        try await send("GET", "/v1/digest", query: [URLQueryItem(name: "kind", value: kind)])
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

    func checkHabit(_ id: Int, done: Bool) async throws -> Habit {
        try await send("POST", "/v1/habits/\(id)/check", body: HabitCheck(done: done))
    }

    func updateHabit(_ id: Int, _ habit: HabitNew) async throws -> Habit {
        try await send("PATCH", "/v1/habits/\(id)", body: habit)
    }

    func uploadHealthDays(_ days: [HealthDay]) async throws -> HealthUploadResult {
        try await send("POST", "/v1/health/days", body: HealthUpload(days: days), timeout: 60)
    }

    func wake(_ request: WakeRequest) async throws -> WakeResult {
        try await send("POST", "/v1/wake", body: request)
    }

    func today(date: Date? = nil) async throws -> TodayResponse {
        let query = date.map { [URLQueryItem(name: "date", value: Wire.dayString($0))] } ?? []
        return try await send("GET", "/v1/today", query: query)
    }

    func syncReminders(cursor: String?, changes: [ReminderChange]) async throws -> SyncResponse {
        try await send("POST", "/v1/reminders/sync",
                       body: SyncRequest(cursor: cursor, changes: changes), timeout: 60)
    }

    func registerDevice(_ device: DeviceRegistration) async throws {
        let _: OKResponse = try await send("POST", "/v1/devices", body: device)
    }

    func testPush() async throws -> PushTestResult {
        try await send("POST", "/v1/devices/test", body: EmptyBody())
    }

    // MARK: Plumbing

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], auth: Bool = true, timeout: TimeInterval = 30
    ) async throws -> T {
        try await perform(try request(method, path, query: query, auth: auth, timeout: timeout, body: nil))
    }

    private func send<B: Encodable, T: Decodable>(
        _ method: String, _ path: String, body: B, timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try JSONEncoder.api.encode(body)
        return try await perform(try request(method, path, query: [], auth: true, timeout: timeout, body: data))
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw APIError.transport(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        return try decode(data, http)
    }

    private func decode<T: Decodable>(_ data: Data, _ http: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Server error (\(http.statusCode))."
            throw APIError.server(status: http.statusCode, message: message)
        }
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

/// Reads a streamed chat (`text/event-stream`) line by line. Each event has one `data:` line of JSON, handled
/// as soon as it arrives: the line reader drops the blank lines that end an event.
struct EventStream {
    enum Event { case team(TeamMessage), reply(ChatReply), working(agent: String), done(TeamReply) }
    private struct Working: Decodable { let agent: String }
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
