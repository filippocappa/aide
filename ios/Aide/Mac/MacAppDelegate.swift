import AppKit
import UserNotifications

/// APNs on the Mac (docs/API.md, Push, `app: "mac"`): the device token and taps on notifications. The Mac gets the
/// alert pushes only; the silent ones (reminders sync, location) are the phone's, so there's nothing to run here.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var env: AppEnvironment { .shared }
    /// Covers the apps a Screen Time lock covers while it holds.
    @MainActor private var shield: MacShield?

    /// Aide's windows never go in tabs (Aide is one window, its lessons and quizzes cards in it). Off for the whole
    /// app, before any window opens.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        shield = MacShield(screenTime: env.screenTime)
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

    /// A strict lock holds until its end: Quit (⌘Q, the Dock, the menu bar panel) is refused while one is on, since
    /// only Aide enforces it here. Logging out, restarting and shutting down still go through, and Force Quit always
    /// works: it's a commitment, not a jail.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let (lock, until) = env.screenTime.strictOn, !Self.systemIsEnding else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Aide stays open during a strict lock"
        alert.informativeText = "\(lock.title) holds until \(MacGlanceCard.time(until)). Quit works again once it's over."
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate()
        alert.runModal()
        return .terminateCancel
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
