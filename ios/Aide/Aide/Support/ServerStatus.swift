import SwiftUI

/// What the glyph shows: nil when all is well.
struct ServerCondition: Equatable {
    enum Level { case info, warning, problem }
    let symbol: String
    let title: String
    let detail: String
    let level: Level

    var color: Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .problem: .red
        }
    }

    /// The project Aide's server runs from on cappa (`~/Developer/aide`).
    static let aideProject = "aide"
    /// A status older than this: the watcher isn't writing, so only `/v1/health` counts.
    static let stale: TimeInterval = 90
    /// Up for less than this: just restarted (the voice still loading).
    static let fresh: TimeInterval = 75

    /// `answering`: `/v1/health` said ok. `reached`: the host answered at all (either request). `host`: the status,
    /// nil when it couldn't be read.
    static func from(answering: Bool, reached: Bool, host: HostStatus?, now: Date = .now) -> ServerCondition? {
        let live = host.flatMap { h in HostStatus.date(h.at).map { now.timeIntervalSince($0) < stale } } == true
            ? host : nil
        let reasons = live.map(Self.reasons) ?? ""

        guard answering else {
            if !reached {
                return ServerCondition(symbol: "wifi.slash", title: "Can't reach cappa",
                                       detail: "Tailscale is off on this device, or cappa is down.", level: .problem)
            }
            switch live?.aide.state {
            case "inactive", "deactivating":
                return ServerCondition(symbol: "pause.circle.fill", title: "Aide is stopped",
                                       detail: reasons.isEmpty ? "Someone stopped it on cappa." : reasons,
                                       level: .warning)
            case "failed":
                return ServerCondition(symbol: "exclamationmark.triangle.fill", title: "Aide crashed",
                                       detail: reasons.isEmpty ? "It's in the logs on cappa." : reasons,
                                       level: .problem)
            case "activating", "active":
                return ServerCondition(symbol: "arrow.clockwise.circle.fill", title: "Aide is starting",
                                       detail: reasons.isEmpty ? "Back in a moment." : reasons, level: .warning)
            default:
                return ServerCondition(symbol: "exclamationmark.triangle.fill", title: "Aide isn't answering",
                                       detail: "cappa is up, but Aide doesn't answer.", level: .problem)
            }
        }
        guard let live else { return nil }
        if let since = HostStatus.date(live.aide.since), now.timeIntervalSince(since) < fresh {
            return ServerCondition(symbol: "arrow.clockwise.circle.fill", title: "Aide just restarted",
                                   detail: "The voice is still loading for a minute.", level: .info)
        }
        if live.claude.contains(where: { $0.busy && $0.project == aideProject }) {
            return ServerCondition(symbol: "hammer.fill", title: "Claude is working on Aide",
                                   detail: "It may restart the server in a moment.", level: .warning)
        }
        if !live.dev.isEmpty || live.claude.contains(where: \.busy) {
            return ServerCondition(symbol: "memorychip", title: "cappa is busy",
                                   detail: reasons + " Aide may be slow, or stopped to make room.", level: .info)
        }
        return nil
    }

    /// "Claude is working in roenlabs. Android emulator and Metro are running."
    static func reasons(_ host: HostStatus) -> String {
        var parts: [String] = []
        let busy = host.claude.filter(\.busy).map(\.project)
        if !busy.isEmpty {
            parts.append("Claude is working in \(Set(busy).sorted().formatted(.list(type: .and))).")
        }
        if !host.dev.isEmpty {
            parts.append("\(host.dev.formatted(.list(type: .and))) \(host.dev.count == 1 ? "is" : "are") running.")
        }
        return parts.joined(separator: " ")
    }

    /// Everything the host said, one line each, for the popover.
    static func lines(_ host: HostStatus, now: Date = .now) -> [String] {
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        var out: [String] = []
        let since = HostStatus.date(host.aide.since).map { " since \(time($0))" } ?? ""
        let state: String = switch host.aide.state {
        case "active": "Aide running\(since)"
        case "inactive": "Aide stopped\(since)"
        case "failed": "Aide crashed\(since)"
        case "activating": "Aide starting"
        case "deactivating": "Aide stopping"
        default: "Aide: \(host.aide.state)"
        }
        out.append(state)
        if let voice = host.voice, voice.state != "active", host.aide.state == "active" {
            out.append("Voice \(voice.state)")
        }
        for s in host.claude {
            out.append("Claude in \(s.project): \(s.busy ? "working" : "idle")")
        }
        if !host.dev.isEmpty { out.append("Running: \(host.dev.formatted(.list(type: .and)))") }
        if let m = host.memory {
            let free = String(format: "%.1f", Double(m.availableMb) / 1024)
            let budget = m.aideMaxMb.map { " · Aide's budget \($0 / 1024) GB" } ?? ""
            out.append("Memory: \(free) GB free\(budget)")
        }
        if let at = HostStatus.date(host.at) {
            out.append(now.timeIntervalSince(at) < stale ? "Checked \(time(at))"
                       : "The watcher on cappa last wrote at \(time(at))")
        }
        return out
    }
}

/// Keeps the glyph current: `/v1/health` and the host status, read together.
@MainActor
final class ServerStatus: ObservableObject {
    @Published private(set) var condition: ServerCondition?
    @Published private(set) var host: HostStatus?
    @Published private(set) var checked: Date?
    private let api: APIClient
    private var running = false

    init(api: APIClient) { self.api = api }

    func refresh() async {
        guard !running else { return }
        running = true
        defer { running = false }
        async let health = Self.result { try await self.api.health() }
        async let status = Self.result { try await self.api.hostStatus() }
        let (h, s) = await (health, status)
        if case .failure(APIError.notConfigured) = h { condition = nil; return }
        let answering = (try? h.get())?.ok == true
        let reached = answering || Self.reached(h) || Self.reached(s)
        host = try? s.get()
        checked = .now
        condition = ServerCondition.from(answering: answering, reached: reached, host: host)
    }

    /// Short timeouts: the glyph should say "can't reach" in seconds, not after half a minute.
    private static func result<T>(_ call: @escaping () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await call()) } catch { return .failure(error) }
    }

    /// Anything but a network error means the host answered (a 502 from tailscaled with Aide down, a 404).
    private static func reached<T>(_ r: Result<T, Error>) -> Bool {
        switch r {
        case .success: true
        case .failure(APIError.transport): false
        case .failure: true
        }
    }
}

/// A little glyph by Settings' gear when something's off with the server; a tap says what.
struct ServerStatusGlyph: View {
    @ObservedObject var status: ServerStatus
    @Environment(\.scenePhase) private var scenePhase
    @State private var showing = false

    var body: some View {
        Group {
            if let c = status.condition {
                Button { showing = true } label: {
                    Image(systemName: c.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(c.color)
                        .symbolEffect(.pulse, isActive: c.level != .info)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.title)
                .popover(isPresented: $showing) { ServerStatusPopover(status: status) }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: status.condition)
        // Often while something's off, so it goes away soon after Aide is back.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await status.refresh()
                try? await Task.sleep(for: .seconds(status.condition == nil ? 30 : 8))
            }
        }
    }
}

private struct ServerStatusPopover: View {
    @ObservedObject var status: ServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = status.condition {
                Label(c.title, systemImage: c.symbol)
                    .font(.headline)
                    .foregroundStyle(c.color)
                Text(c.detail).font(.subheadline)
            } else {
                Label("Aide is fine", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            if let host = status.host {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ServerCondition.lines(host), id: \.self) { Text($0) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button("Check again") { Task { await status.refresh() } }
                .font(.subheadline.weight(.semibold))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(width: 290, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
}
