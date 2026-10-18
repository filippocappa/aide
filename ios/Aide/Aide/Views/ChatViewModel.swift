import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var isError = false
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
    @Published private(set) var loadError: String?

    /// Called after the server may have changed reminders or events.
    var onServerChange: (() async -> Void)?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        conversationID = UserDefaults.standard.string(forKey: Self.conversationKey)
    }

    // MARK: Conversations

    func startNewChat() {
        conversationID = nil
        messages = []
        pending = []
    }

    func open(_ conversation: Conversation) async {
        conversationID = conversation.id
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
            if conversation.id == conversationID { startNewChat() }
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
            messages = history.messages.map {
                Message(role: $0.role == "user" ? .user : .assistant, text: $0.text)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Messages

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        messages.append(Message(role: .user, text: text))
        isSending = true
        do {
            if conversationID == nil { conversationID = try await newConversationID() }
            let reply = try await api.chat(text, conversationID: conversationID)
            messages.append(Message(role: .assistant, text: reply.reply))
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
