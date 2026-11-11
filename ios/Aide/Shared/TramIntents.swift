import ActivityKit
import AppIntents

// Not going, on a leave-now tram countdown: the user isn't going to that event after all. In the app and the
// widgets, as the Live Activity's button runs it in the app (docs/API.md, `POST /v1/transit/alerts/{id}/not-going`).

@MainActor private let client = APIClient(config: { AppSettings().apiConfig })

struct NotGoingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Not going"
    static var description = IntentDescription("Ends a tram countdown: you're not going there after all.")
    static var isDiscoverable = false

    @Parameter(title: "Alert") var alert: Int

    init() {}
    init(alert: Int) { self.alert = alert }

    @MainActor
    func perform() async throws -> some IntentResult {
        for activity in Activity<TramActivityAttributes>.activities where activity.attributes.alert == alert {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try? await client.notGoing(alert)
        return .result()
    }
}
