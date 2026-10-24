import SwiftUI
import WidgetKit

/// The day's objectives (and on the large one, the week's), each in its agent's colour; the ones without a measure
/// get a tick box (docs/API.md, "Widgets").
struct ObjectivesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Objectives", provider: ObjectivesProvider()) { ObjectivesWidgetView(entry: $0) }
            .configurationDisplayName("Objectives")
            .description("What your team set out to do today, and how far it's got.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular])
    }
}

struct ObjectivesEntry: TimelineEntry {
    let date: Date
    let overview: Loaded<ObjectivesOverview>?
    var agents: [Agent] = [.aide]
    var configured = true

    /// Accepted ones: proposals wait in the app, dropped ones are gone.
    func shown(_ block: ObjectiveBlock?) -> [Objective] {
        (block?.objectives ?? []).filter { $0.status == "active" || $0.status == "lapsed" }
            .sorted { !$0.done && $1.done }
    }

    var day: [Objective] { shown(overview?.value.day) }
    var week: [Objective] { shown(overview?.value.week) }
    var waiting: Int { overview?.value.waiting ?? 0 }
}

struct ObjectivesProvider: TimelineProvider {
    func placeholder(in context: Context) -> ObjectivesEntry { ObjectivesEntry(date: Date(), overview: nil) }

    func getSnapshot(in context: Context, completion: @escaping (ObjectivesEntry) -> Void) {
        provide({ completion($0.entries[0]) }) { await timeline() }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ObjectivesEntry>) -> Void) {
        provide(completion) { await timeline() }
    }

    @MainActor private func timeline() async -> Timeline<ObjectivesEntry> {
        let now = Date()
        guard WidgetAPI.isConfigured else {
            return Timeline(entries: [ObjectivesEntry(date: now, overview: nil, configured: false)], policy: .after(now + 3600))
        }
        async let overview = WidgetCache.load(ObjectivesOverview.self, "/v1/objectives")
        let entry = ObjectivesEntry(date: now, overview: await overview, agents: await WidgetCache.agents())
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
        return Timeline(entries: [entry], policy: .after(min(now + 30 * 60, midnight)))
    }
}

struct ObjectivesWidgetView: View {
    let entry: ObjectivesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if !entry.configured {
                WidgetNote(text: WidgetNote.setUp)
            } else if entry.overview == nil {
                WidgetNote(text: "Can't reach Aide. Is Tailscale on?")
            } else {
                switch family {
                case .accessoryCircular: gauge
                case .systemSmall: small
                case .systemLarge:
                    VStack(alignment: .leading, spacing: 6) {
                        list("Today", entry.day, limit: 5)
                        if !entry.week.isEmpty { list("This week", entry.week, limit: 4) }
                        Spacer(minLength: 0)
                        waitingNote
                    }
                default:
                    VStack(alignment: .leading, spacing: 6) {
                        list("Today", entry.day, limit: entry.waiting > 0 ? 3 : 4)
                        Spacer(minLength: 0)
                        waitingNote
                    }
                }
            }
        }
        .widgetBackground()
        .widgetURL(URL(string: "aide://objectives"))
    }

    private var done: Int { entry.day.filter(\.done).count }

    private var gauge: some View {
        Gauge(value: Double(done), in: 0...Double(max(entry.day.count, 1))) {
            Image(systemName: "scope")
        } currentValueLabel: {
            Text("\(done)/\(entry.day.count)").monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Today", fresh: entry.overview?.fresh ?? true)
            if entry.day.isEmpty {
                Text(entry.waiting > 0 ? "Proposals are waiting for your OK." : "No objectives for today.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(done)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("of \(entry.day.count) done").font(.caption).foregroundStyle(.secondary)
                }
                // One mark per objective, in its agent's colour: filled once it's done.
                HStack(spacing: 4) {
                    ForEach(entry.day.prefix(8)) { o in
                        PebbleMark(size: 16, figure: Figure(agent: o.agent))
                            .foregroundStyle(entry.agents.agent(o.agent).tint.opacity(o.done ? 1 : 0.25))
                    }
                }
                if let next = entry.day.first(where: { !$0.done }) {
                    Text(next.title).font(.caption).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func list(_ title: String, _ objectives: [Objective], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetHeader(title: objectives.isEmpty ? title : "\(title) \(objectives.filter(\.done).count)/\(objectives.count)",
                         fresh: entry.overview?.fresh ?? true)
            if objectives.isEmpty {
                Text("Nothing set yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(objectives.prefix(limit)) { row($0) }
        }
    }

    private func row(_ o: Objective) -> some View {
        let tint = entry.agents.agent(o.agent).tint
        return HStack(spacing: 7) {
            if o.isManual {
                Button(intent: TickObjectiveIntent(id: o.id, done: !o.done)) { tick(o, tint) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(o.done ? "Not done: \(o.title)" : "Done: \(o.title)")
            } else {
                tick(o, tint)
            }
            Text(o.title).font(.subheadline).lineLimit(1).foregroundStyle(o.done ? .secondary : .primary)
            Spacer(minLength: 0)
            if !o.done, !o.isManual, o.target > 1 {
                Text("\(o.progress)/\(o.target)").font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func tick(_ o: Objective, _ tint: Color) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.35), lineWidth: 1.5)
            if o.done {
                Circle().fill(tint)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else if o.target > 0, o.progress > 0 {
                Circle().trim(from: 0, to: min(Double(o.progress) / Double(o.target), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 17, height: 17)
    }

    @ViewBuilder private var waitingNote: some View {
        if entry.waiting > 0 {
            Label("\(entry.waiting) waiting for your OK", systemImage: "hand.raised")
                .font(.caption2.weight(.medium)).foregroundStyle(.orange)
        }
    }
}
