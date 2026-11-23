import AppKit
import Combine
import UserNotifications

/// APNs on the Mac (docs/API.md, Push, `app: "mac"`): the device token and taps on notifications. The Mac gets the
/// alert pushes only; the silent ones (reminders sync, location) are the phone's, so there's nothing to run here.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var env: AppEnvironment { .shared }
    /// Covers the apps a Screen Time lock covers while it holds, while Aide Guard doesn't (`MacGuard`).
    @MainActor private var shield: MacShield?
    @MainActor private var nudges: MacNudges?
    @MainActor private var guardWatch: MacGuardWatch?
    @MainActor private var serverChanges: AnyCancellable?

    /// Aide's windows never go in tabs (Aide is one window, its lessons and quizzes cards in it). Off for the whole
    /// app, before any window opens.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MacGuard.register()
        guardWatch = MacGuardWatch { [weak self] runs in self?.enforce(here: !runs) }
        // A new server or token in Settings: the Guard gets it too.
        serverChanges = env.settings.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .map { [weak self] _ in self?.env.settings.apiConfig }
            .removeDuplicates()
            .dropFirst()
            .sink { MacGuard.handOff($0) }
        MacLoginItem.setUpOnce()
        MacPeek.shared.start()
        MacCourseFolders.shared.start()
        Task { await env.screenTime.sync() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in env.push.didRegister(token: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in env.push.didFailToRegister(error) }
    }

    /// Closing the window leaves Aide running, so pushes still come and a click on the Dock icon opens it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Screen Time here (shield and counting) only while Aide Guard isn't running; when it is, the Guard gets the
    /// server and does both.
    @MainActor private func enforce(here: Bool) {
        env.screenTime.enforces = here
        if here {
            guard shield == nil else { return }
            MacUsage.shared.start()
            shield = MacShield(screenTime: env.screenTime)
            nudges = MacNudges(api: env.api)
        } else {
            shield?.stop()
            shield = nil
            nudges?.stop()
            nudges = nil
            MacUsage.shared.follow()
            MacGuard.handOff(env.settings.apiConfig)
        }
    }

    /// While Aide Guard runs, quitting changes nothing for the locks. Without it (turned off in Login Items), a strict
    /// lock holds until its end: Quit (⌘Q, the Dock, the menu bar panel) is refused while one is on, since then only
    /// Aide enforces it here, and any other lock asks first: quitting is what left Bedtime unenforced one night (#85).
    /// Logging out, restarting and shutting down still go through, and Force Quit always works: it's a commitment,
    /// not a jail.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.systemIsEnding, shield != nil else { return .terminateNow }
        if let (lock, until) = env.screenTime.strictOn {
            let alert = NSAlert()
            alert.messageText = "Aide stays open during a strict lock"
            alert.informativeText = "\(lock.title) holds until \(MacGlanceCard.time(until)). Quit works again once it's over."
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate()
            alert.runModal()
            return .terminateCancel
        }
        guard let (lock, until) = env.screenTime.current else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Aide during \(lock.title)?"
        alert.informativeText = "\(lock.title) holds until \(MacGlanceCard.time(until)). Aide is what locks this Mac's "
            + "apps and sites: quit it, and they're open until Aide runs again."
        alert.addButton(withTitle: "Keep Aide Open")
        alert.addButton(withTitle: "Quit Anyway")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    /// Whether this quit comes from logging out, restarting or shutting down (the quit Apple Event's reason).
    @MainActor private static var systemIsEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .contains(reason)
    }

    /// Banners while the app is open too, except for what's already on screen (as on the phone's `AppDelegate`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let route = PushRoute(userInfo: userInfo)
        let conversation = (userInfo["aide"] as? [String: Any])?["conversation_id"] as? String
        return await MainActor.run {
            let chat = env.chat
            switch route {
            case .conversation(let id) where chat.isOnScreen && chat.conversationID == id:
                Task { await chat.loadHistory() }
                return []
            case .errand(let id) where BrowserLive.watching[id] != nil
                || (chat.isOnScreen && conversation != nil && chat.conversationID == conversation):
                return []
            default:
                return [.banner, .list, .sound]
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            NSApplication.shared.activate()
            env.push.route = route
            completionHandler()
        }
    }
}
