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
    /// The Moodle screen as a sheet, from a `moodle` notification.
    @Published var showMoodle = false
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

        chat.onServerChange = { [weak self] in
            await self?.sync.sync()
            await self?.screenTime.sync() // "no phone for an hour" said in chat holds at once
            WidgetCenter.shared.reloadAllTimelines() // a reply may have added a reminder, ticked a habit, …
        }
        digest.completeReminder = { [weak sync] reminder, done in await sync?.setCompleted(reminder, done) ?? false }
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
        location.refresh()
        live.appBecameActive()
        await sync.sync()
        await screenTime.sync()
        await agents
        await history
        await conversations
        await digestLoad
        await pushRefresh
        _ = await healthUpload
        await health.writeLogged()
        await health.writeMeals()
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
            await chat.newChat(with: chat.orchestrator)
            if !voice.isActive { await voice.toggle() }
        case .quiz(let id):
            await chat.open(id: id)
            if voice.isActive { voice.stopAll() }
            await voice.start(saying: "Quiz me")
        case .errand(let id):
            guard let errand = try? await api.errand(id) else { return }
            if errand.needsLiveView {
                browser = .errand(id, title: errand.title)
            } else if let conversation = errand.conversationId {
                await chat.open(id: conversation)
            }
        case .health, .chats:
            break // tabs, switched by ContentView
        }
    }

}
