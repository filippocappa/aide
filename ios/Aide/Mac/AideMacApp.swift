import SwiftUI

/// The Mac app: the phone's screens in one window with a sidebar. It talks to the same server with its own
/// URL and token (Settings), kept in this Mac's keychain.
@main
struct AideMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private var env: AppEnvironment { .shared }

    var body: some Scene {
        WindowGroup("Aide") {
            MacRootView()
                .withAideEnvironment(env)
                .frame(minWidth: 820, minHeight: 560)
                .task { await env.refreshAll() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await env.refreshAll() } }
                }
                .onOpenURL { url in env.push.route = PushRoute(url: url) }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { MacCommands() }

        Settings {
            SettingsView()
                .withAideEnvironment(env)
                .frame(width: 560, height: 640)
        }
    }
}

extension View {
    /// The objects every shared view reads from the environment, as the phone's `AideApp` hands them over.
    func withAideEnvironment(_ env: AppEnvironment) -> some View {
        environmentObject(env)
            .environmentObject(env.settings)
            .environmentObject(env.sync)
            .environmentObject(env.chat)
            .environmentObject(env.digest)
            .environmentObject(env.voice)
            .environmentObject(env.push)
            .environmentObject(env.health)
            .environmentObject(env.location)
            .environmentObject(env.screenTime)
            // The phone's grouped forms, not the Mac's two-column ones.
            .formStyle(.grouped)
            .tint(Theme.accent)
    }
}

/// The menu bar: a new chat with Aide, and each section of the sidebar on ⌘1…⌘6.
struct MacCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat with Aide") {
                Task { @MainActor in
                    let env = AppEnvironment.shared
                    MacNavigation.shared.section = .team
                    await env.chat.newChat(with: env.chat.orchestrator)
                }
            }
            .keyboardShortcut("n")
        }
        CommandMenu("Go") {
            ForEach(MacSection.allCases) { section in
                Button(section.title) { MacNavigation.shared.section = section }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
            }
            Divider()
            Button("Refresh") { Task { await AppEnvironment.shared.refreshAll() } }
                .keyboardShortcut("r")
        }
    }
}
