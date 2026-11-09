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
        /// PDFs sent with it (#78): from the server, or (before then) the ones picked here, with no id yet.
        var files: [StudyFile] = []
        /// A voice call's row ("Call with Professor · 4:12"), not a message.
        var call: VoiceCall?
        /// The specialist who answered a message to Aide directly (the router's pick, #59).
        var routed: Routed?
    }

    /// A message written while the chat's agent was still answering (#69): it goes when that reply is done, one at a
    /// time, in order. Kept per chat (`chat`, nil for a blank chat not yet made on the server) while the app runs.
    struct Queued: Identifiable, Equatable {
        let id = UUID()
        var chat: String?
        let text: String
        let photos: [PickedPhoto]
        var files: [PickedFile] = []

        static func == (a: Queued, b: Queued) -> Bool { a.id == b.id && a.chat == b.chat }
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

    /// Errands whose card comes again further down the chat (a later post about the same one): the earlier cards
    /// fold to a line, so there's one card to act on.
    func errandsAgain(after message: Message) -> Set<Int> {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return [] }
        var ids = Set<Int>()
        for later in messages[(index + 1)...] {
            for case .errands(let errands) in later.attachments { ids.formUnion(errands.map(\.id)) }
        }
        return ids
    }
    /// A reply is on its way in the open chat.
    @Published private(set) var isSending = false
    /// Messages waiting for the reply on its way, in every chat (`queued` is this chat's).
    @Published private(set) var queue: [Queued] = []
    /// Team chat messages waiting for the answers on their way.
    @Published private(set) var teamQueue: [String] = []
    /// Chats with a reply on its way, by conversation id, also after you've left them: the agent's card says so.
    @Published private(set) var working: [String: Working] = [:]
    /// Think harder is on in the open chat (`/v1/history`'s `smart`).
    @Published private(set) var smart = false
    struct Working: Equatable {
        let agent: String
        var status: String
    }
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
    /// Photos and PDFs dropped on another page (the Mac, #78), for the composer of the chat that opens next.
    @Published var composerDrop: Dropped?
    /// The next chat to open starts with the keyboard up ("Ask Aide anything" on the Team tab).
    var typeOnOpen = false
    /// The team talk of the reply on its way, message by message as it streams in.
    @Published private(set) var liveTeam: [TeamMessage] = []
    /// The reply on its way, as it's written. Replaced by the finished reply.
    @Published private(set) var liveReply = ""
    /// What the agent is doing for the reply on its way ("Searching the web for …"), while a tool runs.
    @Published private(set) var liveStep: String? {
        didSet { if liveStep == nil { liveStepKind = nil; livePage = nil } }
    }
    /// The step's kind (docs/API.md, `step`): which icon goes with it.
    @Published private(set) var liveStepKind: String?
    /// The page Aide is browsing, as it shows now (a `page` event), until the reply starts.
    @Published private(set) var livePage: Data?
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

    /// The agent's chats, newest first. Not routine chats: their posts are notes on Today, which opens them.
    /// The old shared chat ("main", from before the app had chats of its own) only while it has something in it.
    func chats(with agent: Agent) -> [Conversation] {
        conversations.filter { self.agent($0.agent).id == agent.id && $0.routine == nil && ($0.id != "main" || $0.preview != nil) }
    }

    /// `agent`'s chats that have `query` in their title or messages, newest first.
    func search(_ query: String, with agent: Agent) async throws -> [Conversation] {
        try await api.searchConversations(query).filter { self.agent($0.agent).id == agent.id && $0.routine == nil }
    }

    /// The digest that fits the time of day: "daily" (morning) before 17:00, "evening" after.
    static func digestKind(at now: Date = Date()) -> String {
        Calendar.current.component(.hour, from: now) < 17 ? "wake" : "evening"
    }

    private func reset() {
        openedDigest = nil
        conversationID = nil
        messages = []
        pending = []
        smart = false
        leaveTurn()
        stopWatchingNotebook()
    }

    /// Another chat is opening: the reply on its way (if any) carries on, shown on its agent's card, not here.
    private func leaveTurn() {
        liveTeam = []
        liveReply = ""
        liveStep = nil
        isSending = conversationID.map { working[$0] != nil } ?? false
    }

    /// What the agent is doing in one of its chats right now ("Asking Secretary…"), nil when it isn't.
    func working(for agent: Agent) -> String? {
        working.values.first { self.agent($0.agent).id == agent.id }?.status
    }

    /// The chat opened with the digest: its first message is Aide's (every other chat starts with yours).
    /// A course's chat can open with Professor too (a notebook proposal in a chat of its own): not a digest.
    var startsWithDigest: Bool {
        messages.first?.role == .assistant && conversations.first(where: { $0.id == conversationID })?.course == nil
    }

    /// This chat's messages waiting to go.
    var queued: [Queued] { queue.filter { $0.chat == conversationID } }

    /// Takes a waiting message back out of the queue (to edit it, or not send it at all).
    @discardableResult
    func unqueue(_ id: UUID) -> Queued? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        return queue.remove(at: index)
    }

    func unqueueTeam(at index: Int) {
        guard teamQueue.indices.contains(index) else { return }
        teamQueue.remove(at: index)
    }

    /// Sends this chat's next waiting message once nothing is on its way.
    private func sendNextQueued() {
        guard !isSending, !isOpening, let index = queue.firstIndex(where: { $0.chat == conversationID }) else { return }
        let next = queue.remove(at: index)
        Task { await send(next.text, photos: next.photos, files: next.files) }
    }

    func open(_ conversation: Conversation) async {
        await open(id: conversation.id)
    }

    func open(id: String) async {
        if id != conversationID { openedDigest = nil; smart = false } // the chat's own, once its history comes
        if !conversations.contains(where: { $0.id == id }) { await loadConversations() } // e.g. from a notification
        agentID = conversations.first { $0.id == id }?.agent ?? orchestrator.id
        conversationID = id
        messages = []
        pending = []
        leaveTurn()
        isChatOpen = true
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        await loadHistory()
        watchNotebook()
        sendNextQueued()
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
        guard !text.isEmpty else { return }
        guard !isPostingTeam else { teamQueue.append(text); return }
        team.append(TeamMessage(from: "user", to: "team", text: text, ts: Wire.local(Date())))
        isPostingTeam = true
        defer {
            isPostingTeam = false
            teamWorking = nil
            if !teamQueue.isEmpty {
                let next = teamQueue.removeFirst()
                Task { await postTeam(next) }
            }
        }
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
            smart = history.smart ?? false
            var loaded = Self.messages(history)
            if let running = history.working { // a turn this app lost track of (it was closed): wait for it
                let asked = Message(role: .user, text: running.text, photos: running.photos ?? [],
                                    files: (running.files ?? []).map { StudyFile(id: $0, name: "PDF") })
                loaded.append(asked)
                messages = loaded
                isSending = true
                working[id] = Working(agent: running.agent, status: running.step ?? "Still working…")
                liveStep = running.step
                Task { await recover(turn: id, asked: asked, reason: "The reply didn't come.") }
                return
            }
            // Keep the existing rows when nothing changed, so a refresh doesn't replay the pop-in animation.
            // Attachments count: a reminder ticked elsewhere should show as ticked.
            func content(_ list: [Message]) -> [String] {
                list.map {
                    "\($0.role == .user ? "u" : "a")|\($0.text)|\($0.attachments.hashValue)|\($0.team.count)"
                        + "|\(max($0.photos.count, $0.localPhotos.count))|\($0.files.count)|\($0.call?.id ?? 0)"
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

    /// The history's messages, each call's row where it started.
    static func messages(_ history: HistoryResponse) -> [Message] {
        var calls = (history.calls ?? []).compactMap { call in call.started.map { (call, $0) } }
        var list: [Message] = []
        for message in history.messages {
            let at = message.ts.flatMap(Wire.parse)
            while let first = calls.first, let at, first.1 <= at {
                list.append(Message(role: .assistant, text: "", call: first.0))
                calls.removeFirst()
            }
            list.append(Message(role: message.role == "user" ? .user : .assistant, text: message.text,
                                attachments: message.attachments, consulted: message.consulted, team: message.team,
                                routine: message.routine, photos: message.photos, files: message.files,
                                routed: message.routed))
        }
        list += calls.map { Message(role: .assistant, text: "", call: $0.0) }
        return list
    }

    // MARK: Voice calls

    /// This chat's id on the server, made now for a blank new chat: a call needs one before anything is said.
    func openConversation() async -> String? {
        if let conversationID { return conversationID }
        guard !isSending else { return nil }
        conversationID = try? await newConversationID()
        return conversationID
    }

    /// What a call did to this chat (docs/API.md, "Voice calls").
    func callEvent(_ event: LiveCall.Event) {
        switch event {
        case .team(let message):
            liveTeam.append(message)
        case .turn(let turn):
            appendTurn(turn)
            liveTeam = [] // the reply carries them all
            Task { await onServerChange?() }
        case .answered(let ids, _, let result):
            answered(ids: ids, result: result)
            Task { await onServerChange?() }
        case .ended:
            liveTeam = []
            Task { // the server keeps the call when it closes: its row, the title, the card's last line
                try? await Task.sleep(for: .seconds(1))
                await loadHistory()
                await loadConversations()
            }
        default:
            break
        }
    }

    /// A request said in a call and its reply, as a typed turn shows them; Confirm works as usual.
    func appendTurn(_ turn: LiveCall.Turn) {
        messages.append(Message(role: .user, text: turn.text))
        messages.append(Message(role: .assistant, text: turn.reply.reply, attachments: turn.reply.attachments,
                                consulted: turn.reply.consulted, team: turn.reply.team))
        pending = turn.reply.pending
    }

    /// A spoken yes or no to queued actions: off the Confirm card, and the result as after a tap.
    func answered(ids: [Int], result: String?) {
        pending.removeAll { ids.contains($0.id) }
        if let result, !result.isEmpty { messages.append(Message(role: .assistant, text: result)) }
    }

    /// The stream was lost after the message went out (the app in the background, the network gone), but the server
    /// carries on with the turn and saves it; its history says `working` meanwhile. Asks every few seconds until the
    /// reply is in. The agent's Live Activity is left to the server, which ends it with the reply (docs/API.md, "Chat").
    private func recover(turn: String, asked: Message, reason: String) async {
        working[turn]?.status = "Still working…"
        var misses = 0
        var history: HistoryResponse?
        while history == nil || history?.working != nil {
            if history != nil || misses > 0 { try? await Task.sleep(for: .seconds(3)) }
            do {
                history = try await api.history(limit: 200, conversationID: turn)
                misses = 0
                if let step = history?.working?.step {
                    working[turn]?.status = step
                    if (conversationID ?? "main") == turn { liveStep = step }
                }
            } catch {
                misses += 1
                if misses >= 20 { break } // a minute without the server: give up
            }
        }
        working[turn] = nil
        let here = (conversationID ?? "main") == turn
        let list = history?.messages ?? []
        let answered = list.last?.role == "assistant"
            && list.dropLast().last.map { $0.role == "user" && $0.text == asked.text } == true
        guard let history, answered else {
            live?.agentFinished(conversation: turn, reply: reason, failed: true)
            guard here else { return }
            messages.append(Message(role: .assistant, text: reason, isError: true, team: liveTeam))
            liveTeam = []
            liveReply = ""
            liveStep = nil
            isSending = false
            sendNextQueued()
            return
        }
        live?.agentFinished(conversation: turn, reply: list.last?.text ?? "")
        if here {
            liveTeam = []
            liveReply = ""
            liveStep = nil
            isSending = false
            messages = Self.messages(history)
            sendNextQueued()
        } else {
            await loadConversations()
        }
        await onServerChange?()
    }

    // MARK: Messages

    /// Sends a message; the reply shows as it's written. `onDraft` gets the draft each time it grows, and true
    /// when it started over (text written before a tool call is dropped). Photos and PDFs go up first; the text
    /// may then be empty. A PDF goes up for its chat (#78), so a new chat is made before it.
    func send(_ raw: String, photos: [PickedPhoto] = [], files: [PickedFile] = [], voice: Bool = false,
              onDraft: ((String, Bool) -> Void)? = nil) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty || !files.isEmpty else { return }
        guard !isSending, !isOpening else { // a reply is on its way: this one goes after it (#69)
            queue.append(Queued(chat: conversationID, text: text, photos: photos, files: files))
            return
        }
        let asked = Message(role: .user, text: text, localPhotos: photos.map(\.jpeg),
                            files: files.map { StudyFile(id: $0.id.uuidString, name: $0.name, pages: $0.pages) })
        messages.append(asked)
        isSending = true
        liveReply = ""
        liveStep = nil
        let speaker = agentID
        var started: String? // the turn's chat, once known
        do {
            var ids: [String] = []
            for photo in photos { ids.append(try await api.uploadPhoto(photo.jpeg)) }
            if conversationID == nil {
                conversationID = try await newConversationID()
                // What was queued in the blank chat belongs to the one just made.
                for i in queue.indices where queue[i].chat == nil { queue[i].chat = conversationID }
            }
            var fileIDs: [String] = []
            for file in files {
                fileIDs.append(try await api.uploadChatPDF(file.url, name: file.name,
                                                           conversationID: conversationID ?? "main").id)
            }
            let turn = conversationID ?? "main"
            // You may leave the chat while the reply is on its way: from then on it only updates the agent's card,
            // and the reply lands in the chat's history (shown when you open it again).
            let here = { [weak self] in (self?.conversationID ?? "main") == turn }
            started = turn
            working[turn] = Working(agent: speaker, status: "Thinking…")
            live?.agentStarted(conversation: turn, agent: agent)
            let reply = try await api.chatLive(text, photos: ids, files: fileIDs, conversationID: conversationID, voice: voice, onText: { [weak self] delta, restart in
                guard let self else { return }
                working[turn]?.status = "Writing…"
                live?.agentUpdate(conversation: turn, status: "writing")
                guard here() else { return }
                liveStep = nil
                liveReply = restart ? delta : liveReply + delta
                onDraft?(liveReply, restart)
            }, onTeam: { [weak self] message in
                guard let self else { return }
                if message.from == speaker, message.to != "user", message.to != "team" {
                    working[turn]?.status = "Asking \(self.agent(message.to).name)…"
                    live?.agentUpdate(conversation: turn, status: "asking", detail: "Asking \(self.agent(message.to).name)")
                }
                if here() { liveTeam.append(message) }
            }, onStep: { [weak self] who, label, kind in
                guard let self else { return }
                let said = who == speaker ? label : "\(self.agent(who).name): \(label)"
                working[turn]?.status = said
                if here() { liveStep = said; liveStepKind = kind }
            }, onPage: { [weak self] jpeg in
                guard let self, here(), liveStep != nil else { return }
                livePage = jpeg
            })
            working[turn] = nil
            live?.agentFinished(conversation: turn, reply: reply.reply)
            if here(), messages.contains(where: { $0.id == asked.id }) {
                messages.append(Message(role: .assistant, text: reply.reply, attachments: reply.attachments,
                                        consulted: reply.consulted, team: reply.team.isEmpty ? liveTeam : reply.team,
                                        routed: reply.routed))
                pending = reply.pending
                if let id = reply.conversationId { conversationID = id }
                liveTeam = []
                liveReply = ""
                liveStep = nil
                isSending = false
                if writing == nil { watchNotebook() } // "yes" to a proposal starts the writing
                sendNextQueued()
            } else if here() { // left and came back while it was on its way: the history has it all now
                liveTeam = []
                liveReply = ""
                liveStep = nil
                isSending = false
                await loadHistory()
                sendNextQueued()
            } else {
                await loadConversations() // the card's last line
            }
            await onServerChange?()
        } catch APIError.transport(let reason) where started != nil {
            await recover(turn: started ?? "main", asked: asked, reason: reason)
        } catch {
            let turn = started ?? conversationID ?? "main"
            working[turn] = nil
            live?.agentFinished(conversation: turn, reply: error.localizedDescription, failed: true)
            guard (conversationID ?? "main") == turn else { return } // you've left: the card stops saying so
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true, team: liveTeam))
            liveTeam = []
            liveReply = ""
            liveStep = nil
            isSending = false
            sendNextQueued()
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
            // What ran may post in this chat a moment later (an Esse3 sign-up's card): load it then.
            try? await Task.sleep(for: .seconds(1.5))
            await loadHistory()
        } catch {
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
            isActing = false
        }
    }

    /// Think harder on or off for this chat; flipped back when the server says no.
    func setSmart(_ on: Bool) async {
        smart = on
        do {
            try await api.think(conversationID: conversationID, on: on)
        } catch {
            smart = !on
            messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
        }
    }
}
