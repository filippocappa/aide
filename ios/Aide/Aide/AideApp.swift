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

    /// Show banners while the app is open too, except a message for the chat on screen: that one is loaded into it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let route = PushRoute(userInfo: notification.request.content.userInfo)
        return await MainActor.run {
            let chat = env.chat
            guard case .conversation(let id) = route, chat.isOnScreen, chat.conversationID == id else {
                return [.banner, .list, .sound]
            }
            Task { await chat.loadHistory() }
            return []
        }
    }

    /// A tap. Not the `async` variant: its generated thunk calls UIKit's completion handler off the main
    /// thread, which UIKit asserts against (the crash in #17). Here the handler runs on the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            env.push.route = route
            completionHandler()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @State private var tab = Tab.chat
    @State private var objectivesWaiting = 0

    enum Tab { case chat, objectives, study, health, settings }

    var body: some View {
        TabView(selection: $tab) {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            ObjectivesView(waiting: $objectivesWaiting)
                .tabItem { Label("Objectives", systemImage: "scope") }
                .tag(Tab.objectives)
                .badge(objectivesWaiting)
            StudyView()
                .tabItem { Label("Study", systemImage: "book") }
                .tag(Tab.study)
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
            // Simulator screenshots: `-previewTab objectives`, `health` (or `habits`), `study` or `settings`.
            if settings.isPreview, let name = UserDefaults.standard.string(forKey: "previewTab") {
                tab = switch name {
                case "objectives": .objectives
                case "health", "habits": .health
                case "study": .study
                case "settings": .settings
                default: .chat
                }
            }
            #endif
        }
        // The badge, before the tab is first opened; the tab keeps it current after that.
        .task(id: settings.isConfigured) {
            if settings.isConfigured, let o = try? await env.api.objectives() { objectivesWaiting = o.waiting }
        }
        // onReceive also sees a route set before this view existed (a tap that launched the app).
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            if case .moodle = route {} else { tab = .chat } // Moodle opens as a sheet over any tab
            Task { await env.open(route) }
        }
        .sheet(isPresented: $env.showMoodle) {
            NavigationStack {
                MoodleView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { env.showMoodle = false } } }
            }
        }
    }
}
