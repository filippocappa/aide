import ActivityKit
import AppIntents

// Driving on a leave-now tram countdown: the user isn't taking the tram this time. In the app and the widgets, as
// the Live Activity's button runs it in the app (docs/API.md, `POST /v1/transit/alerts/{id}/driving`).

@MainActor private let client = APIClient(config: { AppSettings().apiConfig })

struct DrivingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Driving instead"
    static var description = IntentDescription("Ends a tram countdown: you're going by car this time.")
    static var isDiscoverable = false

    @Parameter(title: "Alert") var alert: Int

    init() {}
    init(alert: Int) { self.alert = alert }

    @MainActor
    func perform() async throws -> some IntentResult {
        for activity in Activity<TramActivityAttributes>.activities where activity.attributes.alert == alert {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try? await client.drivingInstead(alert)
        return .result()
    }
}
