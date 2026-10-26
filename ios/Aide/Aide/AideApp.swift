import SwiftUI
import UserNotifications
import WidgetKit

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
                .environmentObject(env.location)
                .tint(Theme.accent)
                .task { await env.refreshAll() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await env.refreshAll() } }
                    // Leaving the app: the widgets show what changed in it (check-ins, meals, objectives).
                    if phase == .background { WidgetCenter.shared.reloadAllTimelines() }
                }
                .onOpenURL { url in env.push.route = PushRoute(url: url) }
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
        // A significant move relaunches the app in the background only if monitoring starts again at launch.
        if !env.settings.isPreview { env.location.start() }
        // A Live Activity the server starts wakes the app in the background to hand over its token.
        if !env.settings.isPreview { env.live.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        env.push.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        env.push.didFailToRegister(error)
    }

    /// Silent pushes. `sync`: bring Apple Reminders up to date, so the alarms are set before they're due.
    /// `location`: a tram alert wants to know how far the stop is.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if PushRoute.isLocation(userInfo), env.settings.isConfigured {
            Task { completionHandler(await env.location.sendFresh() ? .newData : .failed) }
            return
        }
        guard PushRoute.isSync(userInfo), env.settings.isConfigured else { return completionHandler(.noData) }
        Task {
            await env.sync.sync()
            WidgetCenter.shared.reloadTimelines(ofKind: "Today")
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
    @EnvironmentObject private var digest: DigestViewModel
    @State private var tab = Tab.today
    /// Things waiting for your OK, on Today's badge.
    @State private var waiting = 0

    enum Tab { case today, chat, study, health, settings }

    var body: some View {
        TabView(selection: $tab) {
            TodayView(waiting: $waiting)
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(Tab.today)
                .badge(waiting)
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
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
            // Simulator screenshots: `-previewTab chat`, `health`, `study` or `settings` (Today otherwise).
            if settings.isPreview, let name = UserDefaults.standard.string(forKey: "previewTab") {
                tab = switch name {
                case "chat", "chats": .chat
                case "health": .health
                case "study": .study
                case "settings": .settings
                default: .today
                }
            }
            #endif
        }
        // The badge, before Today first loads; Today keeps it current after that.
        .task(id: settings.isConfigured) {
            if settings.isConfigured, let a = try? await env.api.approvals() { waiting = a.waiting }
        }
        // onReceive also sees a route set before this view existed (a tap that launched the app).
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            switch route {
            case .today, .digest, .note, .objectives: tab = .today
            case .health: tab = .health; return
            case .chats: tab = .chat; return
            case .moodle: break // a sheet over any tab
            default: tab = .chat
            }
            Task { await env.open(route) }
        }
        .sheet(isPresented: $env.showMoodle) {
            NavigationStack {
                MoodleView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { env.showMoodle = false } } }
            }
        }
        .sheet(item: $env.newFiles) { NewFilesSheet(ids: $0.ids) }
        .sheet(isPresented: $digest.isPresented) { DigestSheet() }
    }
}
