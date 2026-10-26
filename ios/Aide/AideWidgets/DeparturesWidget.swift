import SwiftUI
import WidgetKit

/// The nearest stops' next departures, from where the phone last was (docs/API.md, "Widgets").
struct DeparturesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Departures", provider: DeparturesProvider()) { DeparturesWidgetView(entry: $0) }
            .configurationDisplayName("Departures")
            .description("Trams and buses from the stops near you.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// A stop by name: the two sides of a street are two GTT stops, one widget group.
struct StopGroup: Identifiable {
    struct Row: Identifiable {
        let line: DepartureBoard.Line
        /// Seconds on foot to this side of the street.
        let walk: Int?
        let stop: String

        var id: String { stop + "|" + line.id }
    }

    let name: String
    let walk: Int?
    /// Soonest first.
    let rows: [Row]

    var id: String { name }
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

    /// The boards by stop name, nearest first, each with its lines that still have a departure.
    var groups: [StopGroup] {
        var names: [String] = []
        var byName: [String: [DepartureBoard]] = [:]
        for board in boards {
            if byName[board.stop.name] == nil { names.append(board.stop.name) }
            byName[board.stop.name, default: []].append(board)
        }
        return names.compactMap { name in
            let boards = byName[name] ?? []
            let rows = boards.flatMap { board in
                board.lines.map { StopGroup.Row(line: $0, walk: board.walk, stop: board.stop.id) }
            }
            .compactMap { row in upcoming(row.line).first.map { (row, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            return rows.isEmpty ? nil : StopGroup(name: name, walk: boards.compactMap(\.walk).min(), rows: rows)
        }
    }

    /// The stops that fit in `slots` lines (a stop's name takes one), each with at least one departure, the rest
    /// shared out in turn.
    func layout(slots: Int, maxGroups: Int) -> [(group: StopGroup, rows: Int)] {
        var chosen: [StopGroup] = []
        var left = slots
        for group in groups where chosen.count < maxGroups && left >= 2 {
            chosen.append(group)
            left -= 2
        }
        var counts = Array(repeating: 1, count: chosen.count)
        var grew = true
        while left > 0 && grew {
            grew = false
            for i in chosen.indices where left > 0 && counts[i] < chosen[i].rows.count {
                counts[i] += 1
                left -= 1
                grew = true
            }
        }
        return Array(zip(chosen, counts)).map { (group: $0, rows: $1) }
    }
}

struct DeparturesProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeparturesEntry { DeparturesEntry(date: Date(), nearby: nil) }

    func getSnapshot(in context: Context, completion: @escaping (DeparturesEntry) -> Void) {
        if context.isPreview {
            return provide({ completion($0.entries[0]) }) {
                Timeline(entries: [DeparturesEntry(date: Date(), nearby: WidgetSamples.nearby)], policy: .never)
            }
        }
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
            } else if entry.groups.isEmpty {
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
        let large = family == .systemLarge
        return VStack(alignment: .leading, spacing: large ? 12 : 8) {
            ForEach(entry.layout(slots: large ? 12 : 5, maxGroups: large ? 4 : 2), id: \.group.id) { item in
                VStack(alignment: .leading, spacing: 5) {
                    header(item.group)
                    ForEach(item.group.rows.prefix(item.rows)) { row($0) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ group: StopGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name).font(.caption.weight(.bold)).lineLimit(1)
            Spacer(minLength: 4)
            if let walk = group.walk {
                Label("\(max(1, walk / 60)) min", systemImage: "figure.walk")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if !(entry.nearby?.fresh ?? true) {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func row(_ row: StopGroup.Row) -> some View {
        let times = entry.upcoming(row.line)
        let live = row.line.arrivals.first { $0.date == times.first }?.live ?? false
        // Under the walk to the stop: probably missed already, so it's dimmed.
        let tooSoon = row.walk.map { times[0].timeIntervalSince(entry.date) < Double($0) } ?? false
        return HStack(spacing: 8) {
            LineBadge(line: row.line.line, vehicle: row.line.vehicle, compact: true)
            if let towards = row.line.towards {
                Text(towards).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(minutes(times[0])).font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(live ? Color.green : Color.primary).opacity(tooSoon ? 0.45 : 1)
            Text(times.count > 1 ? minutes(times[1]) : "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func minutes(_ at: Date) -> String {
        let m = Int((at.timeIntervalSince(entry.date) / 60).rounded(.down))
        return m <= 0 ? "now" : "\(m)′"
    }
}
