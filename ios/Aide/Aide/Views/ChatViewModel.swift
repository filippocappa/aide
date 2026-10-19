import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var isError = false
        var attachments: [Attachment] = []
        /// Agents Aide asked for this reply.
        var consulted: [String] = []
    }

    private static let conversationKey = "conversationID"
    private static let agentKey = "agentID"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var pending: [PendingAction] = []
    @Published private(set) var conversations: [Conversation] = []
    /// nil is a blank new chat: the server conversation is created when the first message is sent.
    @Published private(set) var conversationID: String? {
        didSet { UserDefaults.standard.set(conversationID, forKey: Self.conversationKey) }
    }
    /// Aide first, then the specialists, in the server's order. Just Aide until the server says otherwise.
    @Published private(set) var agents: [Agent] = [.aide]
    /// The agent the current chat belongs to.
    @Published private(set) var agentID: String {
        didSet { UserDefaults.standard.set(agentID, forKey: Self.agentKey) }
    }
    @Published private(set) var isSending = false
    @Published private(set) var isActing = false
    /// A new chat is waiting for its digest greeting.
    @Published private(set) var isOpening = false
    /// The digest kind this chat was opened with, so Details shows the same one. Nil for chats opened later.
    @Published private(set) var openedDigest: String?
    @Published private(set) var loadError: String?

    /// Called after the server may have changed reminders or events.
    var onServerChange: (() async -> Void)?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        conversationID = UserDefaults.standard.string(forKey: Self.conversationKey)
        agentID = UserDefaults.standard.string(forKey: Self.agentKey) ?? Agent.aide.id
    }

    var agent: Agent { agent(agentID) }
    var orchestrator: Agent { agents.first { $0.orchestrator } ?? .aide }

    /// An unknown id (an agent the server dropped) shows as Aide.
    func agent(_ id: String?) -> Agent {
        agents.first { $0.id == id } ?? orchestrator
    }

    func loadAgents() async {
        guard let list = try? await api.agents(), !list.isEmpty else { return } // older server: Aide alone
        agents = list
    }

    // MARK: Conversations

    /// A new chat opens with Pebble's digest greeting (docs/API.md, "Opening a chat with it"): the morning
    /// one before 17:00, the evening one after. A digest-only chat you never answered is cleared away first,
    /// so tapping New chat repeatedly doesn't pile them up. If the server can't, it's a blank chat as before.
    func startNewChat(digest kind: String? = nil) async {
        let unanswered = messages.count == 1 && messages[0].role == .assistant ? conversationID : nil
        reset()
        agentID = orchestrator.id
        if let unanswered { try? await api.deleteConversation(unanswered) }
        isOpening = true
        defer { isOpening = false }
        let kind = kind ?? Self.digestKind()
        guard let conversation = try? await api.createConversation(digest: kind),
              conversationID == nil, messages.isEmpty
        else { return }
        conversationID = conversation.id
        openedDigest = kind
        await loadHistory()
    }

    /// A blank chat with a specialist (or Aide, without the digest greeting). The server conversation is created
    /// with the first message.
    func newChat(with agent: Agent) async {
        let unanswered = messages.count == 1 && messages[0].role == .assistant ? conversationID : nil
        reset()
        agentID = agent.id
        if let unanswered { try? await api.deleteConversation(unanswered) }
    }

    /// The digest that fits the time of day: "daily" (morning) before 17:00, "evening" after.
    static func digestKind(at now: Date = Date()) -> String {
        Calendar.current.component(.hour, from: now) < 17 ? "daily" : "evening"
    }

    private func reset() {
        openedDigest = nil
        conversationID = nil
        messages = []
        pending = []
    }

    /// The chat opened with the digest: its first message is Aide's (every other chat starts with yours).
    var startsWithDigest: Bool { messages.first?.role == .assistant }

    func open(_ conversation: Conversation) async {
        await open(id: conversation.id)
    }

    func open(id: String) async {
        if id != conversationID { openedDigest = nil }
        if !conversations.contains(where: { $0.id == id }) { await loadConversations() } // e.g. from a notification
        agentID = conversations.first { $0.id == id }?.agent ?? orchestrator.id
        conversationID = id
        messages = []
        pending = []
        await loadHistory()
    }

    func loadConversations() async {
        do {
            conversations = try await api.conversations()
        } catch APIError.server(let status, _) where status == 404 {
            conversations = [] // server without conversations yet
        } catch {
            conversations = []
        }
    }

    func delete(_ conversation: Conversation) async {
        do {
            try await api.deleteConversation(conversation.id)
            if conversation.id == conversationID { reset() }
            await loadConversations()
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
        }
    }

    func loadHistory() async {
        guard !isSending, !isActing, let id = conversationID else { return }
        do {
            let history = try await api.history(limit: 200, conversationID: id)
            guard !isSending, !isActing, id == conversationID else { return }
            let loaded = history.messages.map {
                Message(role: $0.role == "user" ? .user : .assistant, text: $0.text, attachments: $0.attachments,
                        consulted: $0.consulted)
            }
            // Keep the existing rows when nothing changed, so a refresh doesn't replay the pop-in animation.
            // Attachments count: a reminder ticked elsewhere should show as ticked.
            func content(_ list: [Message]) -> [String] {
                list.map { "\($0.role == .user ? "u" : "a")|\($0.text)|\($0.attachments.hashValue)" }
            }
            if content(loaded) != content(messages.filter { !$0.isError }) {
                messages = loaded
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Messages

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isOpening else { return }
        messages.append(Message(role: .user, text: text))
        isSending = true
        do {
            if conversationID == nil { conversationID = try await newConversationID() }
            let reply = try await api.chat(text, conversationID: conversationID)
            messages.append(Message(role: .assistant, text: reply.reply, attachments: reply.attachments,
                                    consulted: reply.consulted))
            pending = reply.pending
            if let id = reply.conversationId { conversationID = id }
            isSending = false
            await onServerChange?()
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
            isSending = false
        }
    }

    /// A server without conversations yet answers 404; chat then falls back to the one shared conversation.
    private func newConversationID() async throws -> String? {
        do {
            return try await api.createConversation(agent: agent.orchestrator ? nil : agentID).id
        } catch APIError.server(let status, _) where status == 404 || status == 405 {
            return nil
        }
    }

    func confirm() async { await resolve { try await self.api.confirm() } }
    func cancel() async { await resolve { try await self.api.cancel() } }

    private func resolve(_ call: () async throws -> ActionResult) async {
        guard !isActing else { return }
        isActing = true
        do {
            let result = try await call()
            messages.append(Message(role: .assistant, text: result.result))
            pending = result.pending
            isActing = false
            await onServerChange?()
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
            isActing = false
        }
    }

    func think() async {
        do {
            try await api.think(conversationID: conversationID)
            messages.append(Message(role: .assistant, text: "Using the smarter model for the rest of this chat."))
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
        }
    }
}
