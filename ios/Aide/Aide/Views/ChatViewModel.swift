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
    }

    private static let conversationKey = "conversationID"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var pending: [PendingAction] = []
    @Published private(set) var conversations: [Conversation] = []
    /// nil is a blank new chat: the server conversation is created when the first message is sent.
    @Published private(set) var conversationID: String? {
        didSet { UserDefaults.standard.set(conversationID, forKey: Self.conversationKey) }
    }
    @Published private(set) var isSending = false
    @Published private(set) var isActing = false
    /// A new chat is waiting for its digest greeting.
    @Published private(set) var isOpening = false
    @Published private(set) var loadError: String?

    /// Called after the server may have changed reminders or events.
    var onServerChange: (() async -> Void)?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        conversationID = UserDefaults.standard.string(forKey: Self.conversationKey)
    }

    // MARK: Conversations

    /// A new chat opens with Pebble's digest greeting (docs/API.md, "Opening a chat with it"): the morning
    /// one before 17:00, the evening one after. A digest-only chat you never answered is cleared away first,
    /// so tapping New chat repeatedly doesn't pile them up. If the server can't, it's a blank chat as before.
    func startNewChat(digest kind: String? = nil) async {
        let unanswered = messages.count == 1 && messages[0].role == .assistant ? conversationID : nil
        reset()
        if let unanswered { try? await api.deleteConversation(unanswered) }
        isOpening = true
        defer { isOpening = false }
        guard let conversation = try? await api.createConversation(digest: kind ?? Self.digestKind()),
              conversationID == nil, messages.isEmpty
        else { return }
        conversationID = conversation.id
        await loadHistory()
    }

    /// The digest that fits the time of day: "daily" (morning) before 17:00, "evening" after.
    static func digestKind(at now: Date = Date()) -> String {
        Calendar.current.component(.hour, from: now) < 17 ? "daily" : "evening"
    }

    private func reset() {
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
                Message(role: $0.role == "user" ? .user : .assistant, text: $0.text, attachments: $0.attachments)
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
            messages.append(Message(role: .assistant, text: reply.reply, attachments: reply.attachments))
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
            return try await api.createConversation().id
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
