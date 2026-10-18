import SwiftUI

/// Builds the object graph once and keeps the three screens in step with each other.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let api: APIClient
    let sync: ReminderSyncService
    let chat: ChatViewModel
    let today: TodayViewModel

    init() {
        let settings = AppSettings()
        let api = APIClient(config: { [weak settings] in settings?.apiConfig })
        let sync = ReminderSyncService(api: api, settings: settings)
        let chat = ChatViewModel(api: api)
        let today = TodayViewModel(api: api, sync: sync)
        self.settings = settings
        self.api = api
        self.sync = sync
        self.chat = chat
        self.today = today

        // The assistant may have created reminders or moved events: sync, then redraw Today.
        chat.onServerChange = { [weak self] in await self?.syncAndReloadToday() }
    }

    /// Launch and return-to-foreground.
    func refreshAll() async {
        guard settings.isConfigured else { return }
        async let history: Void = chat.loadHistory()
        await syncAndReloadToday()
        await history
    }

    func syncAndReloadToday() async {
        await sync.sync()
        await today.load()
    }
}
