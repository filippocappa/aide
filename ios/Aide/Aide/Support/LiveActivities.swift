import ActivityKit
import UIKit

/// The app's side of the Live Activities (docs/API.md, "Live Activities"): it hands the server the tokens it pushes
/// to, and starts an agent's activity when a message goes out. The server starts tram countdowns and routine runs
/// itself, and keeps every activity up to date; the widget extension draws them.
@MainActor
final class LiveActivities {
    private let api: APIClient
    private var started = false
    /// Agent activities started here and not over yet, by key.
    private var agents: [String: Activity<AgentActivityAttributes>] = [:]
    /// Activities whose tokens are already being handed over, by ActivityKit id.
    private var followed: Set<String> = []
    /// Told whether a tram's activity is on, so the phone's location is followed closely while one is.
    var onTrams: (@MainActor (Bool) -> Void)?

    init(api: APIClient) { self.api = api }

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    private var environment: String { PushService.environment }

    /// At launch, a background one included: a push-to-start wakes the app briefly so it can send the new
    /// activity's update token.
    func start() {
        guard !started else { return }
        started = true
        watch(TramActivityAttributes.self, kind: "tram", key: \.key)
        watch(AgentActivityAttributes.self, kind: "agent", key: \.key)
        checkTrams()
        Task {
            for await on in ActivityAuthorizationInfo().activityEnablementUpdates where !on {
                // Turned off in iOS Settings: the server goes back to plain pushes.
                try? await api.deleteLiveToken(kind: "tram")
                try? await api.deleteLiveToken(kind: "agent")
            }
        }
    }

    private func watch<A: ActivityAttributes>(_: A.Type, kind: String, key: KeyPath<A, String>) {
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<A>.pushToStartTokenUpdates where enabled {
                    try? await api.registerLiveToken(kind: kind, token: PushService.hex(data), environment: environment)
                }
            }
        }
        for activity in Activity<A>.activities { follow(activity, key: activity.attributes[keyPath: key]) }
        Task {
            for await activity in Activity<A>.activityUpdates { follow(activity, key: activity.attributes[keyPath: key]) }
        }
    }

    /// Sends the activity's update token (and each new one) under its key; a swipe that dismisses it stops the pushes.
    private func follow<A: ActivityAttributes>(_ activity: Activity<A>, key: String) {
        guard followed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                try? await api.registerLiveActivity(key: key, token: PushService.hex(data), environment: environment)
            }
        }
        checkTrams()
        Task {
            for await state in activity.activityStateUpdates {
                checkTrams()
                if state == .dismissed { try? await api.deleteLiveActivity(key: key) }
            }
        }
    }

    private func checkTrams() {
        onTrams?(Activity<TramActivityAttributes>.activities.contains {
            $0.activityState == .active || $0.activityState == .stale
        })
    }

    // MARK: An agent at work

    /// A message went out in `conversation` ("team" for the Team chat): the agent's activity, which shows once
    /// you leave the app. The server keeps it going from here.
    func agentStarted(conversation: String, agent: Agent) {
        guard enabled else { return }
        let key = "agent:\(conversation)"
        if let previous = agents.removeValue(forKey: key) {
            Task { await previous.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = AgentActivityAttributes(key: key, agent: agent.id, name: agent.name, color: agent.color,
                                                 conversation: conversation, title: nil)
        let content = ActivityContent(state: AgentActivityAttributes.ContentState.working(),
                                      staleDate: Date().addingTimeInterval(10 * 60))
        guard let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) else { return }
        agents[key] = activity
        follow(activity, key: key)
    }

    /// What the reply's stream says while the app is still running; the server sends the same for when it isn't.
    func agentUpdate(conversation: String, status: String, detail: String = "") {
        guard let activity = agents["agent:\(conversation)"] else { return }
        var state = activity.content.state
        guard state.status != status || state.detail != detail else { return }
        state.status = status
        state.detail = detail
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))) }
    }

    /// The reply is in. Read here with the app open, the activity goes at once and the server is told not to push;
    /// in the background it shows the reply, and the server ends it with an alert.
    func agentFinished(conversation: String, reply: String, failed: Bool = false) {
        let key = "agent:\(conversation)"
        guard let activity = agents.removeValue(forKey: key) else { return }
        if UIApplication.shared.applicationState == .active {
            Task {
                try? await api.deleteLiveActivity(key: key)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        var state = activity.content.state
        state.status = failed ? "failed" : "done"
        state.detail = failed ? reply : ""
        state.text = failed ? "" : Self.firstLine(reply)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Back in the app: replies already in have been seen, so their activities go.
    func appBecameActive() {
        for activity in Activity<AgentActivityAttributes>.activities where activity.content.state.isOver {
            let key = activity.attributes.key
            Task {
                try? await api.deleteLiveActivity(key: key)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        return plain.count > 140 ? String(plain.prefix(139)) + "…" : plain
    }
}
