import AppIntents

// Logging a meal from Control Center, the Lock Screen or the Action Button: opens the app on the Food tab with the
// camera up, or the box to describe it. In both targets (a control that opens the app must be), but it runs in the
// app, which sets `MealLog.open`.

enum MealLogWay: String, AppEnum {
    case photo, describe

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "How"
    static var caseDisplayRepresentations: [MealLogWay: DisplayRepresentation] = [
        .photo: "Take a photo",
        .describe: "Describe it",
    ]
}

enum MealLog {
    /// Set by the app at launch; shows the camera or the describe box.
    @MainActor static var open: ((MealLogWay) -> Void)?
}

struct LogMealIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a meal"
    static var description = IntentDescription("Opens Aide with the camera up, or a box to describe what you ate.")
    static var openAppWhenRun = true

    @Parameter(title: "How", default: .photo) var way: MealLogWay

    init() {}
    init(way: MealLogWay) { self.way = way }

    static var parameterSummary: some ParameterSummary { Summary("Log a meal: \(\.$way)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        MealLog.open?(way)
        return .result()
    }
}
