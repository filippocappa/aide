import SwiftUI
import WidgetKit

/// The team, each figure opening its chat; the small one and the Lock Screen's start talking to Aide
/// (docs/API.md, "Widgets").
struct TeamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Team", provider: TeamProvider()) { TeamWidgetView(entry: $0) }
            .configurationDisplayName("Your team")
            .description("Open a chat with any of them, or talk to Aide.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct TeamEntry: TimelineEntry {
    let date: Date
    var agents: [Agent] = [.aide]
}

struct TeamProvider: TimelineProvider {
    func placeholder(in context: Context) -> TeamEntry { TeamEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (TeamEntry) -> Void) {
        if context.isPreview {
            return provide({ completion($0.entries[0]) }) {
                Timeline(entries: [TeamEntry(date: Date(), agents: WidgetSamples.agents)], policy: .never)
            }
        }
        provide({ completion($0.entries[0]) }) { await timeline() }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TeamEntry>) -> Void) {
        provide(completion) { await timeline() }
    }

    /// The team rarely changes: once a day is plenty.
    @MainActor private func timeline() async -> Timeline<TeamEntry> {
        let now = Date()
        return Timeline(entries: [TeamEntry(date: now, agents: await WidgetCache.agents())], policy: .after(now + 86_400))
    }
}

struct TeamWidgetView: View {
    let entry: TeamEntry
    @Environment(\.widgetFamily) private var family

    private var aide: Agent { entry.agents.first(where: \.orchestrator) ?? .aide }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                PebbleMark(size: 30, figure: aide.figure)
            }
            .widgetURL(URL(string: "aide://voice"))
            .containerBackground(for: .widget) { Color.clear }
        case .systemSmall:
            talk.widgetBackground().widgetURL(URL(string: "aide://voice"))
        default:
            grid.widgetBackground()
        }
    }

    private var talk: some View {
        VStack(spacing: 8) {
            AgentMark(agent: aide, size: 64)
            Label("Talk to \(aide.name)", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.card, in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(entry.agents.prefix(5)) { agent in
                Link(destination: URL(string: "aide://agent/\(agent.id)")!) {
                    VStack(spacing: 6) {
                        AgentMark(agent: agent, size: 46)
                        Text(agent.name).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
