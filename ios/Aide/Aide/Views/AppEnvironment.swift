import SwiftUI
import WidgetKit

/// Builds the object graph once and keeps the three screens in step with each other.
@MainActor
final class AppEnvironment: ObservableObject {
    /// One per process: the app delegate, the screens and the "I'm up" shortcut all use it.
    static let shared = AppEnvironment()

    let settings: AppSettings
    let api: APIClient
    let sync: ReminderSyncService
    let chat: ChatViewModel
    let digest: DigestViewModel
    let push: PushService
    let health: HealthService
    let location: LocationService
    let live: LiveActivities
    let screenTime: ScreenTimeService
    let voice = VoiceController()
    /// The message box's microphone: dictation, written down on the server.
    let dictation = Dictation()
    /// Whether the server answers, and what's going on on cappa (the glyph by Settings' gear).
    let server: ServerStatus
    /// The Moodle screen as a sheet, from a `moodle` notification.
    @Published var showMoodle = false
    /// Settings, as a sheet over the tabs (the gear in Team's corner; on first launch until the app is set up).
    @Published var showSettings = false
    /// The files a `moodle` notification was about, listed in a sheet.
    @Published var newFiles: NewFiles?
    /// The Team chat, from a widget or a Live Activity (`aide://team`); the home screen opens it and clears this.
    @Published var showTeam = false
    /// Where Today should scroll to; Today clears it.
    @Published var todayFocus: TodayFocus?
    /// The Today page, open over the Team tab.
    @Published var showToday = false
    /// The live view of an errand that needs you, from its push or Live Activity, over everything.
    @Published var browser: BrowserTarget?
    /// Logging a meal from Control Center: the Health tab opens the camera or the describe box and clears this.
    @Published var mealLog: MealLogWay?
    /// A payment to open on the Money page (a "Money in" push); Money clears it.
    @Published var openPayment: Int?
    /// A course page to open from an `open` card (`aide://study/…`); the Study tab follows it and clears this.
    @Published var studyLink: StudyLink?
    /// The focus session on now (docs/API.md, "Focus sessions"), for the Study pages' card.
    @Published var focus: FocusSession?
    /// A Settings page to open from an `open` card (`aide://settings/<page>`); Settings follows it and clears this.
    @Published var settingsPage: String?

    private init() {
        let settings = AppSettings()
        let api = APIClient(config: { [weak settings] in settings?.apiConfig })
        let sync = ReminderSyncService(api: api, settings: settings)
        let chat = ChatViewModel(api: api)
        self.settings = settings
        self.api = api
        self.sync = sync
        self.chat = chat
        self.digest = DigestViewModel(api: api)
        self.server = ServerStatus(api: api)
        self.push = PushService(api: api)
        self.health = HealthService(api: api)
        let location = LocationService(api: api)
        self.location = location
        self.live = LiveActivities(api: api)
        let screenTime = ScreenTimeService(api: api)
        self.screenTime = screenTime
        live.onTrams = { on in location.follow(on) }
        location.onSent = { [live] in live.resendTokens() }
        chat.live = live

        // The assistant may have created reminders or moved events: sync.
        voice.languageCode = { [weak settings] in settings?.voiceLanguage ?? "en-US" }
        voice.speaksReplies = { [weak settings] in settings?.speakReplies ?? true }
        voice.transcribe = { [weak settings] wav in
            try await api.transcribe(wav: wav, language: settings?.voiceLanguage ?? "en-US")
        }
        dictation.transcribe = { [weak settings] wav in
            try await api.transcribe(wav: wav, language: settings?.voiceLanguage ?? "en-US")
        }
        voice.onUtterance = { [weak self] text in
            guard let self else { return }
            // You talked over a reply that's still being written: yours goes once it's in.
            while self.chat.isSending { try? await Task.sleep(for: .milliseconds(100)) }
            let spoken = self.voice.replyStarted()
            await self.chat.send(text, voice: true) { draft, restarted in
                self.voice.replyGrew(spoken, draft: draft, restarted: restarted)
            }
            if let reply = self.chat.messages.last, reply.role == .assistant, !reply.isError {
                self.voice.replyDone(spoken, reply.text)
            } else {
                self.voice.stopAll()
            }
        }

        voice.callRequest = { [weak self] in
            guard let self, await self.serverMakesCalls(),
                  let id = await self.chat.openConversation(), id != "main" else { return nil }
            return try? api.voiceCallRequest(conversationID: id)
        }
        voice.onCall = { [weak self] event in self?.chat.callEvent(event) }

        chat.onServerChange = { [weak self] in
            await self?.sync.sync()
            await self?.screenTime.sync() // "no phone for an hour" said in chat holds at once
            WidgetCenter.shared.reloadAllTimelines() // a reply may have added a reminder, ticked a habit, …
        }
        digest.completeReminder = { [weak sync] reminder, done in await sync?.setCompleted(reminder, done) ?? false }
    }

    /// Live calls as the server last said (docs/API.md, "Voice calls"): read at launch, on coming forward, on a
    /// `sync` push and when Settings → Voice changes them. nil until it answers.
    @Published private(set) var voiceStatus: VoiceStatus?
    private var voiceCheckedAt: Date?
    /// While the voice loads after being turned on: asks again until it's ready.
    private var voiceWatch: Task<Void, Never>?

    /// Live calls off in Settings → Voice: no Talk anywhere, only dictation (#82). Not known yet: Talk shows.
    var talkOff: Bool { voiceStatus?.enabled == false }
    /// Just turned on, the voice still loading: Talk is greyed with a spinner.
    var talkLoading: Bool { voiceStatus?.loading == true }

    /// Live calls on or off, again from the server.
    func refreshVoice() async {
        guard settings.isConfigured, !settings.isPreview else { return }
        guard let status = try? await api.voiceStatus() else { return } // unreachable: keep what we knew
        voiceChanged(status)
    }

    /// What the server said about live calls (here, or from Settings → Voice): the next Talk goes by it.
    func voiceChanged(_ status: VoiceStatus) {
        voiceStatus = status
        voiceCheckedAt = .now
        guard status.loading == true, voiceWatch == nil else { return }
        voiceWatch = Task { [weak self] in
            while let self, self.voiceStatus?.loading == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if let fresh = try? await self.api.voiceStatus() {
                    self.voiceStatus = fresh
                    self.voiceCheckedAt = .now
                }
            }
            self?.voiceWatch = nil
        }
    }

    private func serverMakesCalls() async -> Bool {
        if let status = voiceStatus, let at = voiceCheckedAt, at > .now.addingTimeInterval(-300) { return status.live }
        guard let status = try? await api.voiceStatus() else { return false } // unreachable: the turns say why
        voiceChanged(status)
        return status.live
    }

    /// The focus session on now, again: after one starts or ends, at each switch, on return to the app.
    func refreshFocus() async {
        guard settings.isConfigured, !settings.isPreview else { return }
        guard let list = try? await api.focusSessions(days: 1) else { return }
        // On now, else one that finished in the last hour with its check still to do.
        focus = list.current ?? list.sessions.first { s in
            guard s.check == nil, s.minutes > 0, let end = Wire.parse(s.endedAt ?? s.endsAt) else { return false }
            return end <= .now && end > .now.addingTimeInterval(-3600)
        }
    }

    /// Launch and return-to-foreground.
    func refreshAll() async {
        guard settings.isConfigured else { return }
        if settings.isPreview {
            async let agents: Void = chat.loadAgents()
            async let conversations: Void = chat.loadConversations()
            await chat.loadHistory()
            await agents
            await conversations
            return
        }
        async let agents: Void = chat.loadAgents()
        async let history: Void = chat.loadHistory()
        async let conversations: Void = chat.loadConversations()
        async let digestLoad: Void = digest.loadLatest()
        async let pushRefresh: Void = push.refresh()
        async let healthUpload = health.upload()
        async let voiceLoad: Void = refreshVoice()
        location.refresh()
        live.appBecameActive()
        await sync.sync()
        await screenTime.sync()
        await refreshFocus()
        await agents
        await history
        await conversations
        await digestLoad
        await pushRefresh
        await voiceLoad
        _ = await healthUpload
        await health.writeLogged()
        await health.writeMeals()
        await health.writeWeights()
    }

    /// A tapped notification (docs/API.md, Push).
    func open(_ route: PushRoute) async {
        switch route {
        case .today:
            todayFocus = .top
            await sync.sync()
        case .digest:
            todayFocus = .digest
        case .note:
            todayFocus = .notes
        case .objectives:
            todayFocus = .habits
        case .conversation(let id):
            await chat.open(id: id)
        case .moodle(let login, let files):
            if login || files.isEmpty { showMoodle = true } else { newFiles = NewFiles(ids: files) }
        case .team:
            showTeam = true
        case .agent(let id):
            if chat.conversations.isEmpty { await chat.loadConversations() }
            await chat.talk(to: chat.agent(id))
        case .voice:
            let off = talkOff // live calls off: the widget's Talk opens the box to type
            if off { chat.typeOnOpen = true }
            await chat.newChat(with: chat.orchestrator)
            if !off, !voice.isActive { await voice.toggle() }
        case .errand(let id):
            guard let errand = try? await api.errand(id) else { return }
            if errand.needsLiveView {
                browser = .errand(id, title: errand.title)
            } else if let conversation = errand.conversationId {
                await chat.open(id: conversation)
            }
        case .health, .food, .screen, .chats, .meal, .money, .study, .settings, .record:
            break // tabs and Settings, switched by ContentView
        }
    }

}
