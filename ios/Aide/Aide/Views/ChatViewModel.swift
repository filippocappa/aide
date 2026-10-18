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

    @Published private(set) var messages: [Message] = []
    @Published private(set) var pending: [PendingAction] = []
    @Published private(set) var isSending = false
    @Published private(set) var isActing = false
    @Published private(set) var loadError: String?

    /// Called after the server may have changed reminders or events.
    var onServerChange: (() async -> Void)?

    private let api: APIClient

    init(api: APIClient) { self.api = api }

    /// The shared conversation, so Discord messages show up here too.
    func loadHistory() async {
        guard !isSending, !isActing else { return }
        do {
            let history = try await api.history(limit: 200)
            guard !isSending, !isActing else { return }
            messages = history.messages.map {
                Message(role: $0.role == "user" ? .user : .assistant, text: $0.text)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        messages.append(Message(role: .user, text: text))
        isSending = true
        do {
            let reply = try await api.chat(text)
            messages.append(Message(role: .assistant, text: reply.reply))
            pending = reply.pending
            isSending = false
            await onServerChange?()
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
            isSending = false
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

    func newConversation() async {
        do {
            try await api.newConversation()
            messages = []
            pending = []
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
        }
    }

    func think() async {
        do {
            try await api.think()
            messages.append(Message(role: .assistant, text: "Using the smarter model for the rest of this conversation."))
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
        }
    }
}
