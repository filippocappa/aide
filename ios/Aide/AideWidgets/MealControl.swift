import AppIntents
import SwiftUI
import WidgetKit

/// Control Center (and Lock Screen) buttons that open the app straight on logging a meal: the camera, or the box to
/// describe it.
@available(iOS 18.0, *)
struct MealPhotoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MealPhoto") {
            ControlWidgetButton(action: LogMealIntent(way: .photo)) {
                Label("Snap a meal", systemImage: "fork.knife.circle.fill")
            }
        }
        .displayName("Snap a meal")
        .description("Opens Aide's meal camera: your plate, or a packet's barcode.")
    }
}

@available(iOS 18.0, *)
struct MealDescribeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MealDescribe") {
            ControlWidgetButton(action: LogMealIntent(way: .describe)) {
                Label("Describe a meal", systemImage: "text.bubble.fill")
            }
        }
        .displayName("Describe a meal")
        .description("Opens a box to say what you ate.")
    }
}
