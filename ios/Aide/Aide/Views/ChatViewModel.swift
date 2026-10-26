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
        /// What Aide and those agents said to each other on the way.
        var team: [TeamMessage] = []
        /// Set when a routine posted it.
        var routine: RoutineTag?
        /// Photo ids sent with it, from the server.
        var photos: [String] = []
        /// Photos sent from here, shown before they're uploaded.
        var localPhotos: [Data] = []
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
    /// The first answers are in (or failed): until then the chat list shows placeholders.
    @Published private(set) var agentsLoaded = false
    @Published private(set) var conversationsLoaded = false
    /// The agent the current chat belongs to.
    @Published private(set) var agentID: String {
        didSet { UserDefaults.standard.set(agentID, forKey: Self.agentKey) }
    }
    /// ChatView is showing; a push for this chat then lands in it instead of as a banner.
    var isOnScreen = false
    @Published private(set) var isSending = false
    @Published private(set) var isActing = false
    /// A new chat is waiting for its digest greeting.
    @Published private(set) var isOpening = false
    /// An existing chat's history is on its way: the page stays blank rather than flashing the empty state.
    @Published private(set) var isLoadingHistory = false
    /// The digest kind this chat was opened with, so Details shows the same one. Nil for chats opened later.
    @Published private(set) var openedDigest: String?
    @Published private(set) var loadError: String?
    /// A chat is on screen, pushed over the chat list. Opening or starting a chat sets it.
    @Published var isChatOpen = false
    /// The team talk of the reply on its way, message by message as it streams in.
    @Published private(set) var liveTeam: [TeamMessage] = []
    /// The reply on its way, as it's written. Replaced by the finished reply.
    @Published private(set) var liveReply = ""
    /// The agents' group chat, oldest first (docs/API.md, "Team talk").
    @Published private(set) var team: [TeamMessage] = []
    /// The agent writing in the Team chat right now.
    @Published private(set) var teamWorking: String?
    @Published private(set) var isPostingTeam = false
    @Published private(set) var routines: [Routine] = []
    /// The course notebook being written, when this is the course's chat: the progress bar (docs/API.md, "Notebook").
    @Published private(set) var writing: NotebookProgress?
    /// What Professor is doing meanwhile, under the bar: "Writing The IS-LM model, Crowding out".
    @Published private(set) var writingStep: String?
    /// The course whose chat this is (docs/API.md, "Notebook"), for its practice exams.
    var course: (id: Int, name: String?)? {
        guard let id = conversationID, let row = conversations.first(where: { $0.id == id }),
              let course = row.course else { return nil }
        return (course, row.title)
    }
    private var notebookWatch: Task<Void, Never>?

    /// Called after the server may have changed reminders or events.
    /// The agent's Live Activity for a reply on its way (the lock screen shows it once you leave the app).
    var live: LiveActivities?
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
        defer { agentsLoaded = true }
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
        isChatOpen = true
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
        isChatOpen = true
        if let unanswered { try? await api.deleteConversation(unanswered) }
    }

    /// New chats start blank, Aide's too. The digest greeting opens a chat only from its notification.
    func startChat(with agent: Agent) async {
        await newChat(with: agent)
    }

    /// Carry on with the agent's latest chat, or start one if there's none yet.
    func talk(to agent: Agent) async {
        if let latest = chats(with: agent).first { await open(latest) } else { await startChat(with: agent) }
    }

    /// The agent's chats, newest first.
    func chats(with agent: Agent) -> [Conversation] {
        conversations.filter { self.agent($0.agent).id == agent.id }
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
        stopWatchingNotebook()
    }

    /// The chat opened with the digest: its first message is Aide's (every other chat starts with yours).
    /// A course's chat can open with Professor too (a notebook proposal in a chat of its own): not a digest.
    var startsWithDigest: Bool {
        messages.first?.role == .assistant && conversations.first(where: { $0.id == conversationID })?.course == nil
    }

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
        isChatOpen = true
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        await loadHistory()
        watchNotebook()
    }

    // MARK: Notebook progress

    /// While the course's notebook is being written, asks how far it is every few seconds. When it's done the bar
    /// goes and the history reloads, for Professor's message with the result. Nothing for other chats, or an older
    /// server.
    func watchNotebook() {
        stopWatchingNotebook()
        guard let id = conversationID, let course = conversations.first(where: { $0.id == id })?.course else { return }
        notebookWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let status = try? await self?.api.notebook(course: course),
                      let self, self.conversationID == id, !Task.isCancelled else { return }
                guard let proposal = status.writing else {
                    self.writingStep = nil
                    if self.writing != nil {
                        self.writing = nil
                        await self.loadHistory()
                    }
                    return
                }
                self.writing = proposal.progress ?? NotebookProgress(done: 0, total: 0)
                self.writingStep = status.step
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func stopWatchingNotebook() {
        notebookWatch?.cancel()
        notebookWatch = nil
        writing = nil
        writingStep = nil
    }

    func loadConversations() async {
        defer { conversationsLoaded = true }
        do {
            conversations = try await api.conversations()
        } catch APIError.server(let status, _) where status == 404 {
            conversations = [] // server without conversations yet
        } catch {
            conversations = []
        }
    }

    /// An older server has no team chat: it stays empty.
    func loadTeam() async {
        team = (try? await api.team()) ?? []
    }

    /// Writes in the Team chat. Your message shows at once; the answers come in one by one, with whoever is
    /// writing shown as thinking. A failure shows as a note from Aide, like in a chat.
    func postTeam(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPostingTeam else { return }
        team.append(TeamMessage(from: "user", to: "team", text: text, ts: Wire.local(Date())))
        isPostingTeam = true
        defer { isPostingTeam = false; teamWorking = nil }
        live?.agentStarted(conversation: "team", agent: mentioned(in: text) ?? orchestrator)
        do {
            let reply = try await api.postTeam(text) { [weak self] event in
                guard let self else { return }
                switch event {
                case .working(let agent):
                    teamWorking = agent
                    live?.agentUpdate(conversation: "team", status: "writing", detail: "\(self.agent(agent).name) is writing")
                case .team(let message) where message.from != "user": team.append(message)
                default: break
                }
            }
            live?.agentFinished(conversation: "team", reply: reply.messages.last.map { "\(agent($0.from).name): \($0.text)" } ?? "")
            pending = reply.pending
            await loadTeam()
            await onServerChange?()
        } catch {
            live?.agentFinished(conversation: "team", reply: error.localizedDescription, failed: true)
            team.append(TeamMessage(from: orchestrator.id, to: "team", text: error.localizedDescription))
        }
    }

    /// The first agent @mentioned, who answers first in the Team chat.
    private func mentioned(in text: String) -> Agent? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "@" })
        return words.lazy.compactMap { word in
            word.hasPrefix("@") ? self.agents.first { $0.id == word.dropFirst() || $0.name.lowercased() == word.dropFirst() } : nil
        }.first
    }

    // MARK: Routines

    func routines(of agent: Agent) -> [Routine] { routines.filter { $0.agent == agent.id } }

    /// An older server has no routines: the list stays empty.
    func loadRoutines() async {
        routines = (try? await api.routines()) ?? []
    }

    /// Creates the routine (no id) or saves changes to it. Throws so the editor can show what went wrong.
    func save(_ draft: RoutineDraft, id: Int?) async throws {
        if let id {
            var changes = draft
            changes.agent = nil
            let saved = try await api.updateRoutine(id, changes)
            if let i = routines.firstIndex(where: { $0.id == id }) { routines[i] = saved }
        } else {
            routines.append(try await api.createRoutine(draft))
            await loadConversations() // it came with its own chat
        }
    }

    func setEnabled(_ routine: Routine, _ enabled: Bool) async {
        let draft = RoutineDraft(title: routine.title, prompt: routine.prompt, time: routine.time, days: routine.days,
                                 enabled: enabled, watch: routine.isWatch)
        try? await save(draft, id: routine.id)
    }

    func delete(_ routine: Routine) async {
        routines.removeAll { $0.id == routine.id }
        try? await api.deleteRoutine(routine.id)
        await loadRoutines()
    }

    /// Runs it now; returns the chat it posted in, or nil when a watch found nothing to say.
    func run(_ routine: Routine) async throws -> String? {
        let result = try await api.runRoutine(routine.id)
        if let i = routines.firstIndex(where: { $0.id == routine.id }) { routines[i] = result.routine }
        guard result.spoke != false else { return nil }
        await loadConversations()
        return result.conversationId ?? result.routine.conversationId
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
                        consulted: $0.consulted, team: $0.team, routine: $0.routine, photos: $0.photos)
            }
            // Keep the existing rows when nothing changed, so a refresh doesn't replay the pop-in animation.
            // Attachments count: a reminder ticked elsewhere should show as ticked.
            func content(_ list: [Message]) -> [String] {
                list.map {
                    "\($0.role == .user ? "u" : "a")|\($0.text)|\($0.attachments.hashValue)|\($0.team.count)"
                        + "|\(max($0.photos.count, $0.localPhotos.count))"
                }
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

    /// Sends a message; the reply shows as it's written. `onDraft` gets the draft each time it grows, and true
    /// when it started over (text written before a tool call is dropped). Photos go up first; the text may then
    /// be empty.
    func send(_ raw: String, photos: [PickedPhoto] = [], onDraft: ((String, Bool) -> Void)? = nil) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty, !isSending, !isOpening else { return }
        messages.append(Message(role: .user, text: text, localPhotos: photos.map(\.jpeg)))
        isSending = true
        liveReply = ""
        do {
            var ids: [String] = []
            for photo in photos { ids.append(try await api.uploadPhoto(photo.jpeg)) }
            if conversationID == nil { conversationID = try await newConversationID() }
            let turn = conversationID ?? "main"
            live?.agentStarted(conversation: turn, agent: agent)
            let reply = try await api.chatLive(text, photos: ids, conversationID: conversationID, onText: { [weak self] delta, restart in
                guard let self else { return }
                liveReply = restart ? delta : liveReply + delta
                onDraft?(liveReply, restart)
                live?.agentUpdate(conversation: turn, status: "writing")
            }, onTeam: { [weak self] message in
                guard let self else { return }
                liveTeam.append(message)
                if message.from == orchestrator.id, message.to != "user" {
                    live?.agentUpdate(conversation: turn, status: "asking", detail: "Asking \(self.agent(message.to).name)")
                }
            })
            live?.agentFinished(conversation: turn, reply: reply.reply)
            messages.append(Message(role: .assistant, text: reply.reply, attachments: reply.attachments,
                                    consulted: reply.consulted, team: reply.team.isEmpty ? liveTeam : reply.team))
            pending = reply.pending
            if let id = reply.conversationId { conversationID = id }
            liveTeam = []
            liveReply = ""
            isSending = false
            if writing == nil { watchNotebook() } // "yes" to a proposal starts the writing
            await onServerChange?()
        } catch {
            live?.agentFinished(conversation: conversationID ?? "main", reply: error.localizedDescription, failed: true)
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true, team: liveTeam))
            liveTeam = []
            liveReply = ""
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
