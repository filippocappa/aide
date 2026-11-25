import SwiftUI

/// What the glyph shows: nil when all is well.
struct ServerCondition: Equatable {
    enum Level { case info, warning, problem }
    let symbol: String
    let title: String
    /// A word or two by Aide's name ("Stopped").
    let short: String
    let detail: String
    let level: Level

    var color: Color {
        switch level {
        case .info: .yellow
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
    /// Less free memory than this on cappa: Aide may be squeezed (earlyoom steps in under ~1 GB).
    static let lowMemoryMb = 2500

    /// `answering`: `/v1/health` said ok. `reached`: the host answered at all (either request). `host`: the status,
    /// nil when it couldn't be read.
    static func from(answering: Bool, reached: Bool, host: HostStatus?, now: Date = .now) -> ServerCondition? {
        let live = host.flatMap { h in HostStatus.date(h.at).map { now.timeIntervalSince($0) < stale } } == true
            ? host : nil
        let reasons = live.map(Self.reasons) ?? ""
        // Whatever answers on Aide's port while its unit is down isn't Aide (a test server left there).
        let up = answering && !(live.map { ["inactive", "deactivating", "failed"].contains($0.aide.state) } ?? false)

        guard up else {
            if !reached {
                return ServerCondition(symbol: "wifi.slash", title: "Can't reach cappa", short: "Offline",
                                       detail: "Tailscale is off on this device, or cappa is down.", level: .problem)
            }
            if let port = live?.port, live?.aide.state != "active" {
                return ServerCondition(symbol: "exclamationmark.triangle.fill", title: "Aide's port is taken",
                                       short: "Port taken",
                                       detail: "\(port.command) (\(port.project)) is on Aide's port 8787, so Aide can't start "
                                           + "until it's moved or stopped. " + reasons,
                                       level: .problem)
            }
            switch live?.aide.state {
            case "inactive", "deactivating":
                return ServerCondition(symbol: "pause.circle.fill", title: "Aide is stopped", short: "Stopped",
                                       detail: reasons.isEmpty ? "Someone stopped it on cappa." : reasons,
                                       level: .warning)
            case "failed":
                return ServerCondition(symbol: "exclamationmark.triangle.fill", title: "Aide crashed", short: "Down",
                                       detail: reasons.isEmpty ? "It's in the logs on cappa." : reasons,
                                       level: .problem)
            case "activating", "active":
                return ServerCondition(symbol: "arrow.clockwise.circle.fill", title: "Aide is starting", short: "Starting",
                                       detail: reasons.isEmpty ? "Back in a moment." : reasons, level: .warning)
            default:
                return ServerCondition(symbol: "exclamationmark.triangle.fill", title: "Aide isn't answering", short: "Down",
                                       detail: "cappa is up, but Aide doesn't answer.", level: .problem)
            }
        }
        guard let live else { return nil }
        if let since = HostStatus.date(live.aide.since), now.timeIntervalSince(since) < fresh {
            return ServerCondition(symbol: "arrow.clockwise.circle.fill", title: "Aide just restarted", short: "Warming up",
                                   detail: "The voice is still loading for a minute.", level: .info)
        }
        if live.claude.contains(where: { $0.busy && $0.project == aideProject }) {
            return ServerCondition(symbol: "hammer.fill", title: "Claude is working on Aide", short: "Claude on it",
                                   detail: "It may restart the server in a moment.", level: .warning)
        }
        // Busy only when Aide is at risk: app development running beside it, or little memory left. A Claude session
        // at work in another project alone isn't.
        let low = live.memory.map { $0.availableMb < lowMemoryMb } ?? false
        if !live.dev.isEmpty || !live.claims.isEmpty || live.held != nil || low {
            let running = live.dev.isEmpty ? ""
                : "\(live.dev.formatted(.list(type: .and))) \(live.dev.count == 1 ? "is" : "are") running. "
            let memory = live.memory.map { String(format: "%.1f GB free. ", Double($0.availableMb) / 1024) } ?? ""
            return ServerCondition(symbol: "memorychip", title: "cappa is busy", short: "Busy",
                                   detail: running + (low ? memory : "") + steppedBack(live),
                                   level: .info)
        }
        return nil
    }

    /// What Aide did about app development beside it (#83), for the Busy popover.
    static func steppedBack(_ host: HostStatus) -> String {
        guard let held = host.held else { return "Aide may be slow, or stopped to make room." }
        guard let by = held.by else {
            return "Aide let its voice go to make room; it loads again in a couple of minutes."
        }
        if !held.ready { return "Aide is finishing a call, then lets its voice go for \(by)." }
        return "Aide let its voice go for \(by), and recordings wait to be transcribed. Both come back a couple of "
            + "minutes after it stops; meanwhile Talk works a turn at a time."
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
        if let held = host.held, host.aide.state == "active" {
            out.append(held.by.map { held.ready ? "Voice off while \($0) runs" : "Voice off once the call ends, for \($0)" }
                       ?? "Voice back in a couple of minutes")
        } else if let voice = host.voice, voice.state != "active", host.aide.state == "active" {
            // aide-voice restarts by itself, so stopped means Live calls were turned off (Settings → Voice).
            out.append(voice.state == "inactive" ? "Voice off (Live calls)" : "Voice \(voice.state)")
        }
        for s in host.claude {
            out.append("Claude in \(s.project): \(s.busy ? "working" : "idle")")
        }
        if !host.dev.isEmpty { out.append("Running: \(host.dev.formatted(.list(type: .and)))") }
        for c in host.claims { out.append("Claimed by \(c.who): \(c.what)") }
        if let port = host.port { out.append("Port 8787: \(port.command) (\(port.project))") }
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

/// A short coloured line and a word after Aide's name on the Team page: green when Aide is ready, yellow while
/// app development runs beside it on cappa (or Aide stepped back for it, #83), memory is low or Aide warms up, orange while it's stopped, starting or being worked on, red when it's down.
/// A tap says why. Nothing until the first check.
struct ServerStatusLine: View {
    @ObservedObject var status: ServerStatus
    @Environment(\.scenePhase) private var scenePhase
    @State private var showing = false

    private var color: Color { status.condition?.color ?? .green }

    var body: some View {
        // A ZStack, not a Group: an empty Group drops its modifiers, and the task below would never run.
        ZStack {
            if status.checked != nil {
                HStack(spacing: 5) {
                    let line = Capsule().fill(color.gradient).frame(width: 14, height: 4)
                    if let c = status.condition, c.level != .info { // breathing only while it's stopped or down
                        line.phaseAnimator([1.0, 0.35]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.9) }
                    } else {
                        line
                    }
                    Text(status.condition?.short ?? "Ready")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
                .padding(.vertical, 6) // a bigger target
                .contentShape(Rectangle())
                // Over the card's own button, which opens the chat.
                .highPriorityGesture(TapGesture().onEnded { showing = true })
                .accessibilityElement(children: .combine)
                .accessibilityLabel(status.condition?.title ?? "Aide is ready")
                .accessibilityAddTraits(.isButton)
                .popover(isPresented: $showing) { ServerStatusPopover(status: status) }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status.condition)
        // Often while something's off, so it turns green soon after Aide is back.
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
