import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center (and Lock Screen) button that logs one of a limit habit, e.g. a coffee (#21). Pick the habit
/// when adding the control.
@available(iOS 18.0, *)
struct HabitControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "LogHabit", intent: HabitControlConfiguration.self) { config in
            ControlWidgetButton(action: LogHabitIntent(habit: config.habit ?? HabitEntity(id: 0, name: "Habit"))) {
                Label(config.habit?.name ?? "Log one", systemImage: "plus.circle")
            }
        }
        .displayName("Log one")
        .description("Adds one to a habit with a daily limit.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, *)
struct HabitControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Habit to log"

    @Parameter(title: "Habit") var habit: HabitEntity?
}
