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
    }
}
