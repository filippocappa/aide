import AppIntents

/// "I'm up": tells the server you just woke up, so it sends the wake-up briefing (docs/API.md, "Wake-up
/// briefing"). Meant for a Shortcuts automation, Sleep → Waking Up → Run Immediately, but works by hand too.
struct WakeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "I'm up"
    static var description = IntentDescription(
        "Tells Aide you just woke up, so it sends your wake-up briefing. Add it to a Waking Up automation in Shortcuts.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AppEnvironment.shared.health.wake(source: "shortcut")
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

struct AideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeUpIntent(),
                    phrases: ["I'm up in \(.applicationName)", "Tell \(.applicationName) I'm up"],
                    shortTitle: "I'm up",
                    systemImageName: "sun.horizon")
    }
}
