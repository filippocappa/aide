import ActivityKit
import SwiftUI
import WidgetKit

/// An agent at work on a reply, a routine or notes (with how far it's got), then its first line (docs/API.md,
/// "Live Activities").
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.background)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentMark(agent: a.agentModel, size: 36).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentElapsed(state: s).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(a.title ?? a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.line(name: a.name)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        AgentProgress(state: s, tint: a.agentModel.tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
            } compactLeading: {
                PebbleMark(size: 20, figure: a.agentModel.figure).foregroundStyle(a.agentModel.tint)
            } compactTrailing: {
                if let total = s.total, let done = s.done, !s.isOver {
                    Text("\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(a.agentModel.tint)
                } else {
                    AgentStatusIcon(state: s, tint: a.agentModel.tint)
                }
            } minimal: {
                PebbleMark(size: 18, figure: a.agentModel.figure).foregroundStyle(a.agentModel.tint)
            }
            .widgetURL(a.url)
            .keylineTint(a.agentModel.tint)
        }
    }
}

extension AgentActivityAttributes {
    /// Enough of an Agent for its figure and colour.
    var agentModel: Agent {
        Agent(id: agent, name: name, role: "", color: color, orchestrator: agent == Agent.aide.id, starters: [])
    }
}

/// The time it's been at it, counting up while it works.
struct AgentElapsed: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if state.isOver {
            Text(state.status == "done" ? "Done" : "Failed")
        } else {
            Text(state.sinceDate, style: .timer).monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 48)
        }
    }
}

/// A notes job's topics: a bar and "2 of 5 topics". Nothing for the rest.
struct AgentProgress: View {
    let state: AgentActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        if let total = state.total, total > 0, let done = state.done, !state.isOver {
            HStack(spacing: 8) {
                ProgressView(value: Double(min(done, total)), total: Double(total)).tint(tint)
                Text("\(done) of \(total) topics").font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

struct AgentStatusIcon: View {
    let state: AgentActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        switch state.status {
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
        case "failed": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case "asking": Image(systemName: "person.2.fill").foregroundStyle(tint)
        case "writing": Image(systemName: "text.cursor").foregroundStyle(tint)
        default: ProgressView().tint(tint)
        }
    }
}

struct AgentLockScreen: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        let agent = attributes.agentModel
        HStack(alignment: .top, spacing: 12) {
            AgentMark(agent: agent, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(attributes.title.map { "\(agent.name) · \($0)" } ?? agent.name)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    AgentElapsed(state: state).font(.caption).foregroundStyle(.secondary)
                }
                Text(state.line(name: agent.name)).font(.subheadline)
                    .foregroundStyle(state.isOver ? .primary : .secondary).lineLimit(3)
                AgentProgress(state: state, tint: agent.tint).padding(.top, 4)
            }
        }
        .padding(16)
    }
}
