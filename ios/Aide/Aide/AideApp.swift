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
                .environmentObject(env.screenTime)
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
        // The Control Center's meal buttons open the app and run here.
        MealLog.open = { [env] way in env.push.route = .meal(way) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        env.push.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        env.push.didFailToRegister(error)
    }

    /// Silent pushes. `sync`: bring Apple Reminders up to date, so the alarms are set before they're due, set the
    /// Screen Time locks, and write the habit counts and meals logged through Aide to Health.
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
            await env.screenTime.sync()
            await env.health.writeLogged()
            await env.health.writeMeals()
            await env.health.writeWeights()
            WidgetCenter.shared.reloadTimelines(ofKind: "Today")
            completionHandler(env.sync.lastError == nil ? .newData : .failed)
        }
    }

    /// Show banners while the app is open too, except for what's already on screen: a message for the chat on screen
    /// (it's loaded into it), or an errand whose chat or live view is open.
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
    @State private var tab = Tab.chat
    /// Things waiting for your OK, on the Team tab's badge.
    @State private var waiting = 0

    enum Tab { case chat, study, health, food, settings }

    var body: some View {
        TabView(selection: $tab) {
            ChatsView(waiting: $waiting)
                .tabItem { Label("Team", systemImage: "person.3") }
                .tag(Tab.chat)
                .badge(waiting)
            StudyView()
                .tabItem { Label("Study", systemImage: "book") }
                .tag(Tab.study)
            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag(Tab.health)
            FoodView()
                .tabItem { Label("Food", systemImage: "fork.knife") }
                .tag(Tab.food)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear {
            if !settings.isConfigured { tab = .settings }
            #if DEBUG
            // Simulator screenshots: `-previewTab today`, `health`, `food`, `study` or `settings` (Team otherwise).
            if settings.isPreview, let name = UserDefaults.standard.string(forKey: "previewTab") {
                tab = switch name {
                case "health": .health
                case "food": .food
                case "study": .study
                case "settings": .settings
                default: .chat
                }
                if name == "today" { env.showToday = true }
            }
            #endif
        }
        // The badge, before the Team tab's strip first loads; the strip and Today keep it current after that.
        .task(id: settings.isConfigured) {
            if settings.isConfigured, let a = try? await env.api.approvals() { waiting = a.waiting }
        }
        // onReceive also sees a route set before this view existed (a tap that launched the app).
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            let onToday: Bool
            switch route {
            case .today, .digest, .note, .objectives: tab = .chat; onToday = true
            case .health: tab = .health; env.showToday = false; return
            case .food: tab = .food; env.showToday = false; return
            case .meal(let way): tab = .food; env.showToday = false; env.mealLog = way; return
            case .chats: tab = .chat; env.showToday = false; return
            case .moodle: onToday = false // a sheet over any tab, once Today is out of the way
            default: tab = .chat; onToday = false
            }
            Task {
                if onToday {
                    env.showToday = true
                } else if env.showToday {
                    env.showToday = false
                    try? await Task.sleep(for: .milliseconds(450)) // let Today slide away first
                }
                await env.open(route)
            }
        }
        .sheet(isPresented: $env.showMoodle) {
            NavigationStack {
                MoodleView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { env.showMoodle = false } } }
            }
        }
        .sheet(item: $env.newFiles) { NewFilesSheet(ids: $0.ids) }
        .sheet(isPresented: $env.showToday) { TodayView(waiting: $waiting) }
        .sheet(isPresented: Binding(get: { digest.isPresented && !env.showToday }, set: { digest.isPresented = $0 })) {
            DigestSheet()
        }
        .sheet(item: $env.browser) { StageSheet(target: $0) }
    }
}
