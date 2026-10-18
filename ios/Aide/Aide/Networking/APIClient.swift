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

    func createConversation() async throws -> Conversation {
        try await send("POST", "/v1/conversations", body: EmptyBody())
    }

    func deleteConversation(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/conversations/\(id)", body: EmptyBody())
    }

    func memory() async throws -> [MemoryItem] {
        let list: MemoryList = try await send("GET", "/v1/memory")
        return list.items
    }

    func addMemory(_ text: String) async throws -> MemoryItem {
        try await send("POST", "/v1/memory", body: MemoryRequest(text: text))
    }

    func deleteMemory(_ id: Int) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/memory/\(id)", body: EmptyBody())
    }

    func today(date: Date? = nil) async throws -> TodayResponse {
        let query = date.map { [URLQueryItem(name: "date", value: Wire.dayString($0))] } ?? []
        return try await send("GET", "/v1/today", query: query)
    }

    func syncReminders(cursor: String?, changes: [ReminderChange]) async throws -> SyncResponse {
        try await send("POST", "/v1/reminders/sync",
                       body: SyncRequest(cursor: cursor, changes: changes), timeout: 60)
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

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
