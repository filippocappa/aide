import CoreLocation
import EventKit
import SwiftUI
import UserNotifications

// What only the phone does, standing in on the Mac with the same names the shared views use: Apple Health, location,
// Live Activities, Screen Time and the Apple Reminders sync stay the phone's (it keeps uploading and syncing, and the
// Mac reads the same server). Each one here does nothing and says it's off.

/// Apple Health lives on the phone; the Mac shows what the phone uploaded.
@MainActor
final class HealthService: ObservableObject {
    let isAvailable = false
    @Published private(set) var hasAsked = false
    @Published private(set) var isUploading = false
    @Published private(set) var lastUpload: Date?
    @Published private(set) var lastError: String?

    enum UploadResult { case sent, skipped, retry }

    init(api: APIClient) {}

    func refreshStatus() async {}
    func requestAccess() async {}
    func startObserving() async {}
    @discardableResult func upload(days: Int = 7) async -> UploadResult { .skipped }
    func writeLogged() async {}
    func writeMeals() async {}
    func writeWeights() async {}
    func wake(source: String) async -> String { "Apple Health is on the phone." }
    /// Without Health the profile starts empty, as on a phone that hasn't allowed it.
    func profile() async -> FoodProfile { FoodProfile() }
}

/// Where the phone is, for tram alerts: the phone's job.
@MainActor
final class LocationService: ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .denied
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastError: String?
    var onSent: (@MainActor () -> Void)?

    init(api: APIClient) {}

    var isOn: Bool { false }
    var isAlways: Bool { false }
    var canAsk: Bool { false }
    func start() {}
    func refresh() {}
    func requestAccess() {}
    func follow(_ on: Bool) {}
    func sendFresh() async -> Bool { false }
}

/// Live Activities are the phone's Lock Screen and Dynamic Island.
@MainActor
final class LiveActivities {
    var onTrams: (@MainActor (Bool) -> Void)?
    /// The next event's countdown (Settings → Notifications on the phone).
    var events = false

    init(api: APIClient) {}

    func start() {}
    func resendTokens() {}
    func agentStarted(conversation: String, agent: Agent) {}
    func agentUpdate(conversation: String, status: String, detail: String = "") {}
    func agentFinished(conversation: String, reply: String, failed: Bool = false) {}
    func appBecameActive() {}
    func chatOpened(conversation: String) {}
}

/// Screen Time locks are set on the phone.
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published private(set) var locks: [ScreenLock] = []
    @Published private(set) var lastError: String?

    init(api: APIClient) {}

    var isAuthorized: Bool { false }
    var current: (lock: ScreenLock, until: Date)? { nil }
    var strictOn: (lock: ScreenLock, until: Date)? { nil }
    func sync() async {}
}

struct ReminderList: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Apple Reminders are synced by the phone alone, so a reminder isn't written twice from two devices.
@MainActor
final class ReminderSyncService: ObservableObject {
    @Published private(set) var authorization: EKAuthorizationStatus = .denied
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lists: [ReminderList] = []

    private let api: APIClient

    init(api: APIClient, settings: AppSettings) { self.api = api }

    var hasAccess: Bool { false }
    func requestAccess() async {}
    func reloadLists() {}
    func sync() async {}
    /// Ticked on the Mac: the server takes it, and the phone's next sync carries it to Apple Reminders.
    func setCompleted(_ reminder: Reminder, _ done: Bool) async -> Bool {
        (try? await api.completeReminder(reminder.id, completed: done)) != nil
    }
}

// MARK: - Cameras

/// What the meal camera ends with (as on the phone, `Views/MealCameraView.swift`).
enum MealCameraResult {
    case photos([PickedPhoto])
    case logged(Meal)
    case library
    case describe
}

/// No meal camera on the Mac: asking for it opens the photo library instead (the phone's "Library" button).
struct MealCameraView: View {
    let tint: Color
    var date: String?
    var conversation: String? = nil
    let done: (MealCameraResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .task {
                dismiss()
                done(.library)
            }
    }
}

/// The phone's system camera; the Mac picks from files and Photos instead.
enum CameraPicker {
    static let isAvailable = false
}

/// On the phone, counts taps anywhere so Pebble bounces; a Mac window has no touches to count.
struct TouchTracker: View {
    @Binding var tapCount: Int
    var body: some View { Color.clear }
}

/// The meal camera's capture session lives on the phone.
enum MealCamera {
    static let isAvailable = false
}
