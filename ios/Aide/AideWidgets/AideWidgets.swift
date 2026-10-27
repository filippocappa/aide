import SwiftUI
import WidgetKit

@main
struct AideWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        HealthWidget()
        ObjectivesWidget()
        TeamWidget()
        DeparturesWidget()
        TramLiveActivity()
        AgentLiveActivity()
        EventLiveActivity()
        if #available(iOS 18.0, *) { HabitControl() }
    }
}
