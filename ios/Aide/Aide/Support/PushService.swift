#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

/// What a tapped notification asks the app to show (docs/API.md, Push).
enum PushRoute: Equatable {
    case today
    /// A digest is ready: Today, on its card.
    case digest(String)
    case conversation(String)
    /// A routine's or watch's post: Today, on the team's notes (its chat opens from there).
    case note(String)
    /// The Chats tab, e.g. after starting a chat from Today.
    case chats
    /// New course files (their ids), or (`login`) the Moodle login has expired.
    case moodle(login: Bool, files: [String] = [])
    /// From widgets and Live Activities (`aide://…` links): the Team chat, an agent's latest chat, talking to Aide.
    case team
    case agent(String)
    case voice
    /// A course chat (its id), with Professor quizzing out loud: "Quiz me" on the course page.
    case quiz(String)
    /// Today's habits and objectives, the Health tab and the Food tab.
    case objectives
    case health
    case food
    /// A browser errand: its live view while it needs you on the page, else its chat.
    case errand(Int)
    /// Logging a meal (the Control Center buttons): the Food tab with the camera up, or the describe box.
    case meal(MealLogWay)

    /// `aide://conversation/<id>`, `aide://team`, `aide://agent/<id>`, `aide://voice`, `aide://today`,
    /// `aide://objectives`, `aide://health`, `aide://food`, `aide://errand/<id>`, `aide://meal/photo` (or `describe`).
    init?(url: URL) {
        guard url.scheme == "aide" else { return nil }
        let id = url.pathComponents.dropFirst().first
        switch url.host {
        case "conversation": guard let id else { return nil }; self = .conversation(id)
        case "agent": guard let id else { return nil }; self = .agent(id)
        case "team": self = .team
        case "voice": self = .voice
        case "today": self = .today
        case "objectives": self = .objectives
        case "health": self = .health
        case "food": self = .food
        case "errand": guard let id = id.flatMap(Int.init) else { return nil }; self = .errand(id)
        case "meal": self = .meal(id.flatMap(MealLogWay.init(rawValue:)) ?? .photo)
        default: return nil
        }
    }

    /// nil for silent pushes, test pushes and kinds this version doesn't know.
    init?(userInfo: [AnyHashable: Any]) {
        guard let aide = userInfo["aide"] as? [String: Any], let kind = aide["kind"] as? String else { return nil }
        switch kind {
        case "reminder": self = .today
        case "digest": self = .digest(aide["digest"] as? String ?? "daily")
        case "message":
            guard let id = aide["conversation_id"] as? String else { return nil }
            self = aide["routine"] != nil ? .note(id) : .conversation(id)
        case "moodle": self = .moodle(login: aide["login"] as? Bool ?? false, files: aide["files"] as? [String] ?? [])
        case "errand":
            guard let id = (aide["errand_id"] as? Int) ?? (aide["errand_id"] as? NSNumber)?.intValue else { return nil }
            self = .errand(id)
        default: return nil
        }
    }

    /// A silent push that asks for a reminders sync.
    static func isSync(_ userInfo: [AnyHashable: Any]) -> Bool { kind(userInfo) == "sync" }

    /// A silent push that asks for the phone's location, for a tram alert.
    static func isLocation(_ userInfo: [AnyHashable: Any]) -> Bool { kind(userInfo) == "location" }

    private static func kind(_ userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["aide"] as? [String: Any])?["kind"] as? String
    }
}

/// Notification permission, the APNs device token and handing it to the server.
@MainActor
final class PushService: ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The server has this device's current token.
    @Published private(set) var isRegistered = false
    @Published private(set) var lastError: String?
    /// Set when a notification is tapped; ContentView acts on it and clears it.
    @Published var route: PushRoute?

    private let api: APIClient
    private var token: String?

    init(api: APIClient) { self.api = api }

    #if DEBUG
    static let environment = "sandbox"
    #else
    static let environment = "production"
    #endif

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Launch and return-to-foreground. Silent pushes need no permission, so the app always registers;
    /// the permission prompt only matters for visible ones, and iOS shows it once.
    func refresh() async {
        #if os(iOS)
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        UIApplication.shared.registerForRemoteNotifications()
        if !isRegistered { await sendToken() }
        #else
        // No pushes to the Mac yet: the server sends with the phone's topic, so the Mac doesn't register.
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #endif
    }

    func didRegister(token data: Data) {
        let new = Self.hex(data)
        if new != token { isRegistered = false }
        token = new
        Task { await sendToken() }
    }

    func didFailToRegister(_ error: Error) {
        lastError = "This device couldn't get a push token: \(error.localizedDescription)"
    }

    private func sendToken() async {
        guard let token, !isRegistered else { return }
        do {
            try await api.registerDevice(DeviceRegistration(token: token, environment: Self.environment,
                                                            name: UIDevice.current.name))
            isRegistered = true
            lastError = nil
        } catch APIError.notConfigured {
            // Settings aren't filled in yet; the next refresh tries again.
        } catch APIError.server(let status, _) where status == 404 {
            lastError = "The server doesn't support push notifications yet."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendTest() async -> (ok: Bool, text: String) {
        do {
            let result = try await api.testPush()
            if result.sent > 0 { return (true, "Sent. It should arrive in a few seconds.") }
            return (false, result.failed > 0
                    ? "Nothing went out. The server's push key may not be set up yet."
                    : "No devices are registered.")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
