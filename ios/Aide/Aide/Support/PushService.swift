import UIKit
import UserNotifications

/// What a tapped notification asks the app to show (docs/API.md, Push).
enum PushRoute: Equatable {
    case today
    case digest(String)
    case conversation(String)
    /// New course files (their ids), or (`login`) the Moodle login has expired.
    case moodle(login: Bool, files: [String] = [])
    /// From widgets and Live Activities (`aide://…` links): the Team chat, an agent's latest chat, talking to Aide.
    case team
    case agent(String)
    case voice
    /// The Objectives and Health tabs.
    case objectives
    case health

    /// `aide://conversation/<id>`, `aide://team`, `aide://agent/<id>`, `aide://voice`, `aide://today`,
    /// `aide://objectives`, `aide://health`.
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
            self = .conversation(id)
        case "moodle": self = .moodle(login: aide["login"] as? Bool ?? false, files: aide["files"] as? [String] ?? [])
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
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        UIApplication.shared.registerForRemoteNotifications()
        if !isRegistered { await sendToken() }
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
