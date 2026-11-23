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
        /// The reply's id on the server, to rate it, and its rating: "up" or "down" (docs/API.md, "Rating a reply").
        var serverID: Int?
        var feedback: String?
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
    /// Messages waiting to go, in every chat (`queued` is this chat's): written while a reply was on its way (#69), or
    /// while the server couldn't be reached (#80). Kept on the device (`ChatCache`), so they outlive the app.
    @Published private(set) var queue: [Outgoing] = [] {
        didSet { if queue != oldValue { cache.saveOutbox(queue) } }
    }
    /// The server can't be reached: the chats show what was kept (#79) and messages wait to be sent (#80).
    @Published private(set) var isOffline = false
    /// While offline: when what shows was last loaded from the server.
    @Published private(set) var shownFrom: Date?
    private var lastLoaded: Date?
    /// Which blank chat is open, for its waiting messages before it's made on the server.
    private var blankID = UUID()
    /// Waiting messages on their way out from another chat than the open one.
    private var inFlight: Set<UUID> = []
    private var flushing = false
    private var reconnect: Task<Void, Never>?
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
    private let cache: ChatCache

    init(api: APIClient, cache: ChatCache? = nil) {
        self.api = api
        self.cache = cache ?? .shared
        conversationID = UserDefaults.standard.string(forKey: Self.conversationKey)
        agentID = UserDefaults.standard.string(forKey: Self.agentKey) ?? Agent.aide.id
        queue = self.cache.loadOutbox()
        self.cache.trimPhotos()
    }

    var agent: Agent { agent(agentID) }
    var orchestrator: Agent { agents.first { $0.orchestrator } ?? .aide }

    /// An unknown id (an agent the server dropped) shows as Aide.
    func agent(_ id: String?) -> Agent {
        agents.first { $0.id == id } ?? orchestrator
    }

    func loadAgents() async {
        defer { agentsLoaded = true }
        // Offline: the ones last seen. An older server: Aide alone.
        guard let list = (try? await api.agents()) ?? api.cached("agents", as: AgentList.self)?.0.agents,
              !list.isEmpty else { return }
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

    /// The agent's chats, newest first, not the archived ones (#81). Not routine chats: their posts are notes on
    /// Today, which opens them. The old shared chat ("main", from before the app had chats of its own) only while it
    /// has something in it.
    func chats(with agent: Agent) -> [Conversation] {
        allChats(with: agent).filter { !$0.isArchived }
    }

    /// The agent's archived chats, newest first: untouched for two weeks, or archived by hand (#81).
    func archivedChats(with agent: Agent) -> [Conversation] {
        allChats(with: agent).filter(\.isArchived)
    }

    private func allChats(with agent: Agent) -> [Conversation] {
        conversations.filter { self.agent($0.agent).id == agent.id && $0.routine == nil && ($0.id != "main" || $0.preview != nil) }
    }

    /// Pins a chat (out of the Archive) or unpins it: shown at once, put back when the server says no.
    func setPinned(_ conversation: Conversation, _ on: Bool) async {
        await change(conversation, pinned: on, archived: nil)
    }

    /// Archives a chat (unpinned) or brings it back.
    func setArchived(_ conversation: Conversation, _ on: Bool) async {
        await change(conversation, pinned: nil, archived: on)
    }

    private func change(_ conversation: Conversation, pinned: Bool?, archived: Bool?) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        let before = conversations[index]
        if let pinned {
            conversations[index].pinned = pinned
            if pinned { conversations[index].archived = false }
        }
        if let archived {
            conversations[index].archived = archived
            if archived { conversations[index].pinned = false }
        }
        do {
            let row = try await api.changeConversation(conversation.id, pinned: pinned, archived: archived)
            if let i = conversations.firstIndex(where: { $0.id == row.id }) {
                conversations[i].pinned = row.pinned
                conversations[i].archived = row.archived
            }
        } catch {
            if let i = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[i] = before }
        }
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
        blankID = UUID()
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
    var queued: [Outgoing] { queue.filter(isHere) }

    /// The waiting message belongs to the open chat.
    private func isHere(_ item: Outgoing) -> Bool {
        if let conversationID { return item.chat == conversationID }
        return item.chat == nil && item.blank == blankID
    }

    /// Takes a waiting message back out of the queue (to edit it, or not send it at all), with its photos and PDFs.
    @discardableResult
    func unqueue(_ id: UUID) -> (text: String, photos: [PickedPhoto], files: [PickedFile])? {
        guard let index = queue.firstIndex(where: { $0.id == id }), !inFlight.contains(id) else { return nil }
        let item = queue[index]
        let (photos, files) = contents(of: item)
        queue.remove(at: index)
        return (item.text, photos, files)
    }

    /// Sends a message the server said no to again.
    func retry(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].failed = nil
        sendNextQueued()
        Task { await flushOutbox() }
    }

    /// A waiting message as a chat row, greyed out by the view.
    func row(for item: Outgoing) -> Message {
        Message(role: .user, text: item.text,
                localPhotos: item.photos.compactMap { try? Data(contentsOf: cache.outboxURL($0)) },
                files: item.files.map { StudyFile(id: $0, name: URL(filePath: $0).lastPathComponent) })
    }

    /// The photos and PDFs kept for a waiting message, read back (PDFs as copies, since the kept ones go once it's sent).
    private func contents(of item: Outgoing) -> ([PickedPhoto], [PickedFile]) {
        (item.photos.compactMap { (try? Data(contentsOf: cache.outboxURL($0))).flatMap(PickedPhoto.init(jpeg:)) },
         item.files.compactMap { PickedFile.copy(of: cache.outboxURL($0)) })
    }

    /// A message to wait, its photos and PDFs kept on the device: for the open chat, or `chat` (`blank` when it isn't
    /// made yet) with `agent`.
    private func outgoing(_ text: String, photos: [PickedPhoto], files: [PickedFile], id: UUID, writtenAt: Date,
                          chat: String?? = nil, blank: UUID? = nil, agent: String? = nil) -> Outgoing {
        let chat = chat ?? conversationID
        return Outgoing(id: id, chat: chat, blank: chat == nil ? (blank ?? blankID) : nil, agent: agent ?? agentID, text: text,
                 photos: photos.compactMap { cache.keepPhoto($0.jpeg) }, files: files.compactMap { cache.keepFile($0.url) },
                 writtenAt: writtenAt)
    }

    func unqueueTeam(at index: Int) {
        guard teamQueue.indices.contains(index) else { return }
        teamQueue.remove(at: index)
    }

    /// Sends this chat's next waiting message once nothing is on its way.
    private func sendNextQueued() {
        guard !isSending, !isOpening, !isOffline,
              let next = queue.first(where: { isHere($0) && $0.failed == nil && !inFlight.contains($0.id) }) else { return }
        let (photos, files) = contents(of: next)
        queue.removeAll { $0.id == next.id }
        Task { await send(next.text, photos: photos, files: files, id: next.id, writtenAt: next.writtenAt) }
    }

    // MARK: Offline (#79, #80)

    /// The server didn't answer: what was kept shows, and it's asked again every so often until it does.
    private func wentOffline() {
        if !isOffline {
            isOffline = true
            shownFrom = lastLoaded ?? shownFrom
        }
        guard reconnect == nil else { return }
        reconnect = Task { [weak self] in
            var wait = 5.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                if (try? await self.api.health()) != nil {
                    self.reconnect = nil
                    self.cameOnline()
                    return
                }
                wait = min(wait * 1.5, 60)
            }
        }
    }

    /// The server answered. Back from offline: the list, the Team chat and the open chat load again, and what waited
    /// goes out (`loadConversations` sends it).
    private func cameOnline() {
        lastLoaded = .now
        guard isOffline else { return }
        isOffline = false
        shownFrom = nil
        reconnect?.cancel()
        reconnect = nil
        Task {
            await loadConversations()
            await loadTeam()
            if isChatOpen { await loadHistory() }
        }
    }

    /// Sends what waited (#80), oldest first: the open chat's as usual, the other chats' here, one at a time, each with
    /// its key, so one sent twice is answered once. From the app coming forward, the server coming back, and on the
    /// phone a background task.
    func flushOutbox() async {
        sendNextQueued()
        guard !flushing, !isOffline else { return }
        flushing = true
        defer { flushing = false }
        var sent = false
        while !isOffline, let next = queue.first(where: { item in
            !isHere(item) && item.failed == nil && !inFlight.contains(item.id) && item.chat.map { working[$0] == nil } ?? true
        }) {
            await sendAway(next)
            sent = true
        }
        if sent { await loadConversations() }
    }

    /// Sends what waited and waits for it: a background task's work.
    func sendWaiting() async {
        await loadConversations()
        while flushing { try? await Task.sleep(for: .milliseconds(300)) }
        await flushOutbox()
    }

    /// Whether anything waits to be sent (a background task is scheduled for it).
    var hasWaiting: Bool { queue.contains { $0.failed == nil } }

    /// A waiting message from a chat that isn't open: the reply lands in the chat's history, the card says it's on its way.
    private func sendAway(_ item: Outgoing) async {
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }
        var turn: String?
        do {
            var chat = item.chat
            if chat == nil { // a new chat, written offline
                let made = try await api.createConversation(agent: agent(item.agent).orchestrator ? nil : item.agent).id
                for i in queue.indices where queue[i].chat == nil && queue[i].blank == item.blank {
                    queue[i].chat = made
                    queue[i].blank = nil
                }
                chat = made
            }
            guard let chat else { return }
            let (photos, files) = contents(of: item)
            var ids: [String] = []
            for photo in photos { ids.append(try await api.uploadPhoto(photo.jpeg)) }
            var fileIDs: [String] = []
            for file in files { fileIDs.append(try await api.uploadChatPDF(file.url, name: file.name, conversationID: chat).id) }
            turn = chat
            working[chat] = Working(agent: item.agent, status: "Thinking…")
            let reply = try await api.chatLive(item.text, photos: ids, files: fileIDs, conversationID: chat,
                                               clientID: item.id, writtenAt: item.writtenAt, onTeam: { _ in })
            working[chat] = nil
            queue.removeAll { $0.id == item.id }
            live?.agentFinished(conversation: chat, reply: reply.reply)
            if conversationID == chat, !isSending { await loadHistory() }
        } catch APIError.transport {
            if let turn { working[turn] = nil }
            wentOffline()
        } catch APIError.server(let status, _) where status == 409 { // already being answered: it'll be in the history
            if let turn { working[turn] = nil }
            queue.removeAll { $0.id == item.id }
        } catch {
            if let turn { working[turn] = nil }
            if let i = queue.firstIndex(where: { $0.id == item.id }) { queue[i].failed = error.localizedDescription }
        }
    }

    /// Keeps the histories of the chats that matter offline: each agent's newest that aren't archived, course chats,
    /// and chats with messages waiting. The rest are dropped from the device.
    private func pruneCache() {
        var keep: Set<String> = ["main"]
        var perAgent: [String: Int] = [:]
        for chat in conversations where !chat.isArchived {
            if chat.course != nil { keep.insert(chat.id); continue }
            let agent = chat.agent ?? ""
            if perAgent[agent, default: 0] < ChatCache.chatsPerAgent {
                keep.insert(chat.id)
                perAgent[agent, default: 0] += 1
            }
        }
        keep.formUnion(queue.compactMap(\.chat))
        cache.keepHistories(keep)
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
            cameOnline()
            pruneCache()
            if hasWaiting { Task { await flushOutbox() } }
        } catch APIError.transport {
            if conversations.isEmpty, let (kept, saved) = api.cached("conversations", as: ConversationList.self) {
                conversations = kept.conversations
                lastLoaded = lastLoaded ?? saved
            }
            wentOffline()
        } catch APIError.server(let status, _) where status == 404 {
            conversations = [] // server without conversations yet
        } catch {
            conversations = []
        }
    }

    /// An older server has no team chat: it stays empty. Offline, it's what was kept.
    func loadTeam() async {
        do {
            team = try await api.team()
            cameOnline()
        } catch APIError.transport {
            if team.isEmpty { team = api.cached("team", as: TeamList.self)?.0.messages ?? [] }
            wentOffline()
        } catch {
            team = []
        }
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
            cache.remove(APIClient.historyKey(conversation.id))
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
                        + "|\($0.serverID ?? 0)|\($0.feedback ?? "")"
                }
            }
            if content(loaded) != content(messages.filter { !$0.isError }) {
                messages = loaded
            }
            loadError = nil
            cameOnline()
        } catch APIError.transport(let reason) {
            // Offline: the chat as it was last seen here (#79), or why there's nothing.
            if messages.isEmpty, let (kept, saved) = api.cached(APIClient.historyKey(id), as: HistoryResponse.self) {
                smart = kept.smart ?? false
                messages = Self.messages(kept)
                lastLoaded = lastLoaded ?? saved
            }
            loadError = messages.isEmpty ? reason : nil
            wentOffline()
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
                                routed: message.routed, serverID: message.id, feedback: message.feedback))
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
    ///
    /// `park` is the message again, when it was sent from here: if the server isn't heard from at all, it may never
    /// have got it, so it waits to be sent again with the same key (#80) instead of being given up on.
    private func recover(turn: String, asked: Message, reason: String, park: (() -> Outgoing)? = nil) async {
        working[turn]?.status = "Still working…"
        var misses = 0
        var reached = false
        var history: HistoryResponse?
        while history == nil || history?.working != nil {
            if history != nil || misses > 0 { try? await Task.sleep(for: .seconds(3)) }
            do {
                history = try await api.history(limit: 200, conversationID: turn)
                misses = 0
                reached = true
                if let step = history?.working?.step {
                    working[turn]?.status = step
                    if (conversationID ?? "main") == turn { liveStep = step }
                }
            } catch {
                misses += 1
                if !reached, misses >= 3, let park { // ~10 s and not a word from the server: it waits
                    working[turn] = nil
                    live?.agentFinished(conversation: turn, reply: "Waiting to send", failed: true)
                    queue.insert(park(), at: 0)
                    if (conversationID ?? "main") == turn {
                        messages.removeAll { $0.id == asked.id }
                        liveTeam = []
                        liveReply = ""
                        liveStep = nil
                        isSending = false
                    }
                    wentOffline()
                    return
                }
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
    ///
    /// `id` is the message's key (`client_id`), the same however often it's sent; `writtenAt` is when it was written,
    /// for one that waited (#80). While offline it waits, kept on the device, and goes when the server is back.
    func send(_ raw: String, photos: [PickedPhoto] = [], files: [PickedFile] = [], voice: Bool = false,
              id: UUID = UUID(), writtenAt: Date = .now, onDraft: ((String, Bool) -> Void)? = nil) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty || !files.isEmpty else { return }
        // A reply is on its way: this one goes after it (#69). Or the server can't be reached: it goes when it's back.
        guard !isSending, !isOpening, !isOffline else {
            queue.append(outgoing(text, photos: photos, files: files, id: id, writtenAt: writtenAt))
            if isOffline { wentOffline() }
            return
        }
        let asked = Message(role: .user, text: text, localPhotos: photos.map(\.jpeg),
                            files: files.map { StudyFile(id: $0.id.uuidString, name: $0.name, pages: $0.pages) })
        messages.append(asked)
        isSending = true
        liveReply = ""
        liveStep = nil
        let speaker = agentID
        let blank = blankID
        var chat = conversationID // the chat it's for, once made
        var started: String? // the turn's chat, once known
        do {
            var ids: [String] = []
            for photo in photos { ids.append(try await api.uploadPhoto(photo.jpeg)) }
            if conversationID == nil {
                conversationID = try await newConversationID()
                chat = conversationID
                // What was queued in the blank chat belongs to the one just made.
                for i in queue.indices where queue[i].chat == nil && queue[i].blank == blankID {
                    queue[i].chat = conversationID
                    queue[i].blank = nil
                }
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
            let reply = try await api.chatLive(text, photos: ids, files: fileIDs, conversationID: conversationID, voice: voice,
                                               clientID: id, writtenAt: writtenAt, onText: { [weak self] delta, restart in
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
                                        routed: reply.routed, serverID: reply.messageId))
                pending = reply.pending
                if let id = reply.conversationId { conversationID = id }
                liveTeam = []
                liveReply = ""
                liveStep = nil
                isSending = false
                if writing == nil { watchNotebook() } // "yes" to a proposal starts the writing
                sendNextQueued()
                Task { _ = try? await api.history(limit: 200, conversationID: turn) } // kept for offline, with the reply
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
            await recover(turn: started ?? "main", asked: asked, reason: reason) { [unowned self] in
                outgoing(text, photos: photos, files: files, id: id, writtenAt: writtenAt, chat: .some(started),
                         agent: speaker)
            }
        } catch APIError.transport {
            // It never reached the server (a photo, the new chat or a PDF couldn't go up): it waits, first in line.
            if messages.contains(where: { $0.id == asked.id }) {
                messages.removeAll { $0.id == asked.id }
                liveTeam = []
                isSending = false
            }
            queue.insert(outgoing(text, photos: photos, files: files, id: id, writtenAt: writtenAt, chat: .some(chat),
                                  blank: blank, agent: speaker), at: 0)
            wentOffline()
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

    /// 👍 or 👎 on a reply, or taken back (nil): shown at once, put back when the server says no. The turn is kept on
    /// the server for the developer to read (docs/API.md, "Rating a reply").
    func rate(_ message: Message, _ rating: String?, note: String? = nil) async {
        guard let serverID = message.serverID,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let before = messages[index].feedback
        messages[index].feedback = rating
        do {
            try await api.rate(messageID: serverID, conversationID: conversationID, rating: rating, note: note)
        } catch {
            if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i].feedback = before }
        }
    }

    /// 👎 on the latest reply that can be rated, with what went wrong ("/report …").
    func reportLast(_ note: String) async {
        guard let last = messages.last(where: { $0.role == .assistant && $0.serverID != nil }) else { return }
        await rate(last, "down", note: note.isEmpty ? nil : note)
    }

    /// The chat as plain text, for "/copy": who said what, in order.
    var transcriptText: String {
        messages.filter { !$0.text.isEmpty }.map { message in
            "\(message.role == .user ? "You" : agent.name): \(message.text)"
        }.joined(separator: "\n\n")
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
