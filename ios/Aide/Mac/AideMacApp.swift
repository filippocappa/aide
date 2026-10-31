import SwiftUI

/// The Mac app: the phone's screens in one window with a sidebar. It talks to the same server with its own
/// URL and token (Settings), kept in this Mac's keychain.
@main
struct AideMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("menuBarItem") private var menuBarItem = true
    private var env: AppEnvironment { .shared }

    var body: some Scene {
        // One window: the chats, the sidebar and what's on screen are one `AppEnvironment`, which a second window
        // would share and fight over. Closing it leaves Aide in the menu bar.
        Window("Aide", id: MacWindow.main) {
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

        MenuBarExtra(isInserted: $menuBarItem) {
            MacMenuBarMenu()
        } label: {
            Image(nsImage: MacMenuBarIcon.image).accessibilityLabel("Aide")
        }

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
            // The phone's switches, not the Mac's checkboxes.
            .toggleStyle(.phoneSwitch)
            .tint(Theme.accent)
    }
}

enum MacWindow {
    static let main = "main"

    @MainActor static func newChat() {
        let env = AppEnvironment.shared
        MacNavigation.shared.section = .team
        Task { await env.chat.newChat(with: env.chat.orchestrator) }
    }
}

/// Pebble's small cut (`brand/logo/pebble-small.svg`: heavier eyes, for 16–32 px), a template image so it takes the
/// menu bar's colour, about as tall as the menu bar's own symbols.
enum MacMenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSImage(named: "MenuBarPebble")?.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The Pebble in the menu bar: Aide's window, a new chat and the sections, with the window closed too.
struct MacMenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Aide") { show() }
        Button("New Chat with Aide") { show(); MacWindow.newChat() }
        Divider()
        ForEach(MacSection.allCases.filter { $0 != .settings }) { section in
            Button(section.title) { show(); MacNavigation.shared.section = section }
        }
        Divider()
        Button("Quit Aide") { NSApplication.shared.terminate(nil) }
    }

    private func show() {
        openWindow(id: MacWindow.main)
        NSApplication.shared.activate()
    }
}

/// The menu bar: a new chat with Aide, and each section of the sidebar on ⌘1…⌘6.
struct MacCommands: Commands {
    @AppStorage("menuBarItem") private var menuBarItem = true
    @AppStorage("macSidebarCollapsed") private var sidebarCollapsed = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat with Aide") { MacWindow.newChat() }
                .keyboardShortcut("n")
        }
        CommandGroup(before: .toolbar) {
            Toggle("Show Section Names", isOn: Binding(get: { !sidebarCollapsed }, set: { sidebarCollapsed = !$0 }))
                .keyboardShortcut("s", modifiers: [.control, .command])
            Divider()
        }
        CommandGroup(after: .appSettings) {
            Toggle("Show in Menu Bar", isOn: $menuBarItem)
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
