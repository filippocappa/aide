import SwiftUI

/// Builds the object graph once and keeps the three screens in step with each other.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let api: APIClient
    let sync: ReminderSyncService
    let chat: ChatViewModel
    let digest: DigestViewModel
    let voice = VoiceController()

    init() {
        let settings = AppSettings()
        let api = APIClient(config: { [weak settings] in settings?.apiConfig })
        let sync = ReminderSyncService(api: api, settings: settings)
        let chat = ChatViewModel(api: api)
        self.settings = settings
        self.api = api
        self.sync = sync
        self.chat = chat
        self.digest = DigestViewModel(api: api)

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
        async let history: Void = chat.loadHistory()
        async let digestLoad: Void = digest.load()
        await sync.sync()
        await history
        await digestLoad
    }

}
