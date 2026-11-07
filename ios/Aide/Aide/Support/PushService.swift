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
    /// Today's habits and objectives, the Health tab (Body, or its Food half) and the Screen tab.
    case objectives
    case health
    case food
    case screen
    /// A browser errand: its live view while it needs you on the page, else its chat.
    case errand(Int)
    /// Logging a meal (the Control Center buttons): Health → Food with the camera up, or the describe box.
    case meal(MealLogWay)
    /// The Money tab, on a payment (money came in) or, with none, on the accounts (a bank link to renew).
    case money(payment: Int?)
    /// From an `open` card in chat: the Study tab, or a course's page, practice exam, study session or lesson.
    case study(StudyLink?)
    /// From an `open` card in chat: Settings, on one of its pages (`digests`, `screentime`, …) or its top.
    case settings(String?)

    /// `aide://conversation/<id>`, `aide://team`, `aide://agent/<id>`, `aide://voice`, `aide://today`,
    /// `aide://objectives`, `aide://health`, `aide://food`, `aide://screen`, `aide://errand/<id>`, `aide://meal/photo`
    /// (or `describe`), `aide://money` (or `aide://money/<payment id>`), `aide://study[/<course>[/practice|/quiz|/lesson]]`
    /// (`?topic=<t_…>&title=…`), `aide://settings[/<page>]`.
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
        case "screen": self = .screen
        case "errand": guard let id = id.flatMap(Int.init) else { return nil }; self = .errand(id)
        case "meal": self = .meal(id.flatMap(MealLogWay.init(rawValue:)) ?? .photo)
        case "money": self = .money(payment: id.flatMap(Int.init))
        case "study": self = .study(StudyLink(url: url))
        case "settings": self = .settings(id)
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
        case "bedtime": self = .settings("bedtime")
        case "passwords": self = .settings("passwords")
        case "esse3":
            let course = (aide["course_id"] as? Int) ?? (aide["course_id"] as? NSNumber)?.intValue
            self = .study(course.map { StudyLink(course: $0) })
        case "finance":
            self = .money(payment: (aide["payment_id"] as? Int) ?? (aide["payment_id"] as? NSNumber)?.intValue)
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

/// A course's page to open on the Study tab (`aide://study/<course>/…`), from an `open` card in chat.
struct StudyLink: Equatable {
    enum Page: String { case course, practice, quiz, due, lesson }
    let course: Int
    var page = Page.course
    /// A notebook topic's id (`t_…`) and title: a lesson's topic, or the one a study session starts on.
    var topic: String?
    var title: String?
    /// A focus session just over (`?focus=f_…` on a quiz): the check after it.
    var focus: String?

    init(course: Int, page: Page = .course, topic: String? = nil, title: String? = nil, focus: String? = nil) {
        self.course = course; self.page = page; self.topic = topic; self.title = title; self.focus = focus
    }

    /// nil for `aide://study` (the tab), or a link this version can't follow.
    init?(url: URL) {
        let parts = url.pathComponents.dropFirst()
        guard let course = parts.first.flatMap(Int.init) else { return nil }
        // A "+" is a space too (form encoding), which URLComponents leaves as it is.
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        let value = { (name: String) in
            query.first { $0.name == name }?.value?.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        let page = parts.dropFirst().first.map { Page(rawValue: $0) } ?? .course
        guard let page, page != .lesson || value("topic") != nil else { return nil }
        self.init(course: course, page: page, topic: value("topic"), title: value("title"), focus: value("focus"))
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
        #if os(macOS)
        // A Mac build without push (Config/Base.xcconfig) has no reason to ask.
        guard UIApplication.canPush else {
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            return
        }
        #endif
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
