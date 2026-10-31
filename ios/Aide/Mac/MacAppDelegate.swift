import AppKit
import UserNotifications

/// APNs on the Mac (docs/API.md, Push, `app: "mac"`): the device token and taps on notifications. The Mac gets the
/// alert pushes only; the silent ones (reminders sync, location) are the phone's, so there's nothing to run here.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var env: AppEnvironment { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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
