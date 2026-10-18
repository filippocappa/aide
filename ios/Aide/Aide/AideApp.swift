import SwiftUI

@main
struct AideApp: App {
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.sync)
                .environmentObject(env.chat)
                .environmentObject(env.today)
                .tint(Theme.accent)
                .task { await env.refreshAll() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await env.refreshAll() } }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var tab = Tab.chat

    enum Tab { case chat, today, settings }

    var body: some View {
        TabView(selection: $tab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            TodayView()
                .tabItem { Label("Today", systemImage: "calendar") }
                .tag(Tab.today)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear { if !settings.isConfigured { tab = .settings } }
    }
}
