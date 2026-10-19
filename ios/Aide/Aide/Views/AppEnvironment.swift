import SwiftUI

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
    let voice = VoiceController()

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

        // The assistant may have created reminders or moved events: sync.
        voice.languageCode = { [weak settings] in settings?.voiceLanguage ?? "en-US" }
        voice.speaksReplies = { [weak settings] in settings?.speakReplies ?? true }
        voice.onUtterance = { [weak self] text in
            guard let self else { return }
            await self.chat.send(text)
            if let reply = self.chat.messages.last, reply.role == .assistant, !reply.isError {
                self.voice.speak(reply.text)
            } else {
                self.voice.stopAll()
            }
        }

        chat.onServerChange = { [weak self] in await self?.sync.sync() }
        digest.completeReminder = { [weak sync] reminder, done in await sync?.setCompleted(reminder, done) ?? false }
    }

    /// Launch and return-to-foreground.
    func refreshAll() async {
        guard settings.isConfigured else { return }
        async let agents: Void = chat.loadAgents()
        async let history: Void = chat.loadHistory()
        async let digestLoad: Void = digest.load()
        async let pushRefresh: Void = push.refresh()
        async let healthUpload = health.upload()
        await sync.sync()
        await agents
        await history
        await digestLoad
        await pushRefresh
        _ = await healthUpload
    }

    /// A tapped notification (docs/API.md, Push).
    func open(_ route: PushRoute) async {
        switch route {
        case .today:
            await sync.sync()
            digest.kind = .daily
            digest.isPresented = true
        case .digest(let kind):
            await chat.startNewChat(digest: kind)
        case .conversation(let id):
            await chat.open(id: id)
        }
    }

}
