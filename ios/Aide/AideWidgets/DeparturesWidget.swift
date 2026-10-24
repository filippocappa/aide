import SwiftUI
import WidgetKit

/// The nearest stops' next departures, from where the phone last was (docs/API.md, "Widgets").
struct DeparturesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Departures", provider: DeparturesProvider()) { DeparturesWidgetView(entry: $0) }
            .configurationDisplayName("Departures")
            .description("Trams and buses from the stops near you.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DeparturesEntry: TimelineEntry {
    let date: Date
    let nearby: Loaded<NearbyBoards>?
    var configured = true

    var boards: [DepartureBoard] { nearby?.value.boards ?? [] }

    /// Each line's arrivals still ahead at the entry's time.
    func upcoming(_ line: DepartureBoard.Line) -> [Date] {
        line.arrivals.compactMap(\.date).filter { $0 > date - 30 }
    }
}

struct DeparturesProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeparturesEntry { DeparturesEntry(date: Date(), nearby: nil) }

    func getSnapshot(in context: Context, completion: @escaping (DeparturesEntry) -> Void) {
        provide({ completion($0.entries[0]) }) { await timeline() }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeparturesEntry>) -> Void) {
        provide(completion) { await timeline() }
    }

    /// One entry a minute for 20 minutes, the minutes counting down from one read; then read again.
    @MainActor private func timeline() async -> Timeline<DeparturesEntry> {
        let now = Date()
        guard WidgetAPI.isConfigured else {
            return Timeline(entries: [DeparturesEntry(date: now, nearby: nil, configured: false)], policy: .after(now + 3600))
        }
        let nearby = await WidgetCache.load(NearbyBoards.self, "/v1/transit/nearby")
        let start = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        let entries = (0..<20).map { DeparturesEntry(date: $0 == 0 ? now : start + Double($0) * 60, nearby: nearby) }
        return Timeline(entries: entries, policy: .after(now + 15 * 60))
    }
}

struct DeparturesWidgetView: View {
    let entry: DeparturesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if !entry.configured {
                WidgetNote(text: WidgetNote.setUp)
            } else if entry.boards.isEmpty {
                WidgetNote(text: entry.nearby == nil ? "Can't reach Aide. Is Tailscale on?"
                                                     : "No stops with departures near you.",
                           symbol: entry.nearby == nil ? "exclamationmark.icloud" : "tram")
            } else {
                content
            }
        }
        .widgetBackground()
    }

    private var content: some View {
        let boards = Array(entry.boards.prefix(family == .systemSmall ? 1 : 2))
        let lines = family == .systemLarge ? 5 : family == .systemSmall ? 3 : 2
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(boards) { board in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(board.stop.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let walk = board.walk {
                            Label("\(max(1, walk / 60)) min", systemImage: "figure.walk")
                                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        }
                        if !(entry.nearby?.fresh ?? true) {
                            Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(board.lines.filter { !entry.upcoming($0).isEmpty }.prefix(lines)) { line in
                        row(line, walk: board.walk)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ line: DepartureBoard.Line, walk: Int?) -> some View {
        let times = entry.upcoming(line)
        let live = line.arrivals.first { $0.date == times.first }?.live ?? false
        // Under the walk to the stop: probably missed already, so it's dimmed.
        let tooSoon = walk.map { times[0].timeIntervalSince(entry.date) < Double($0) } ?? false
        return HStack(spacing: 6) {
            LineBadge(line: line.line, vehicle: line.vehicle, compact: true)
            if family != .systemSmall, let towards = line.towards {
                Text(towards).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(minutes(times[0])).font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(live ? Color.green : Color.primary).opacity(tooSoon ? 0.45 : 1)
            if family != .systemSmall, times.count > 1 {
                Text(minutes(times[1])).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func minutes(_ at: Date) -> String {
        let m = Int((at.timeIntervalSince(entry.date) / 60).rounded(.down))
        return m <= 0 ? "now" : "\(m)′"
    }
}
