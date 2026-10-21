import SwiftUI
import UserNotifications

@main
struct AideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// Owned by the delegate, so pushes that wake the app in the background reach the same objects.
    private var env: AppEnvironment { appDelegate.env }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.sync)
                .environmentObject(env.chat)
                .environmentObject(env.digest)
                .environmentObject(env.voice)
                .environmentObject(env.push)
                .environmentObject(env.health)
                .tint(Theme.accent)
                .task { await env.refreshAll() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await env.refreshAll() } }
                }
        }
    }
}

/// APNs callbacks: the device token, silent sync pushes, and taps on notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var env: AppEnvironment { .shared }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // HealthKit's background wake-ups only reach observers set up during launch.
        Task { if !env.settings.isPreview { await env.health.startObserving() } }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        env.push.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        env.push.didFailToRegister(error)
    }

    /// A silent `sync` push: bring Apple Reminders up to date, so the alarms are set before they're due.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard PushRoute.isSync(userInfo), env.settings.isConfigured else { return completionHandler(.noData) }
        Task {
            await env.sync.sync()
            completionHandler(env.sync.lastError == nil ? .newData : .failed)
        }
    }

    /// Show banners while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { env.push.route = route }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @State private var tab = Tab.chat

    enum Tab { case chat, health, settings }

    var body: some View {
        TabView(selection: $tab) {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag(Tab.health)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear {
            if !settings.isConfigured { tab = .settings }
            #if DEBUG
            // Simulator screenshots: `-previewTab health` (or `habits`) or `settings`.
            if settings.isPreview, let name = UserDefaults.standard.string(forKey: "previewTab") {
                tab = name == "health" || name == "habits" ? .health : name == "settings" ? .settings : .chat
            }
            #endif
        }
        // onReceive also sees a route set before this view existed (a tap that launched the app).
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            tab = .chat
            Task { await env.open(route) }
        }
    }
}
