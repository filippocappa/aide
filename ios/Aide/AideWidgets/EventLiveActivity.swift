import ActivityKit
import SwiftUI
import WidgetKit

/// The next calendar event, counting down from 10 minutes before (docs/API.md, "Live Activities"): a bar filling up
/// to the start, where, how long, the notes' first line and what comes after it.
struct EventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventActivityAttributes.self) { context in
            EventLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.background)
                .widgetURL(URL(string: "aide://today"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EventIcon(size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        EventCountdown(state: s).font(.title2.weight(.bold))
                        Text(s.startDate, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(.headline).lineLimit(1)
                        Text(EventLockScreen.subtitle(a, s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        EventBar(state: s)
                        EventDetails(state: s)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "calendar").foregroundStyle(Theme.accent)
            } compactTrailing: {
                EventCountdown(state: s).font(.caption.weight(.bold)).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "calendar").foregroundStyle(Theme.accent)
            }
            .widgetURL(URL(string: "aide://today"))
            .keylineTint(Theme.accent)
        }
    }
}

/// Minutes to the start, counting down by itself; "Now" once it's on.
struct EventCountdown: View {
    let state: EventActivityAttributes.ContentState

    var body: some View {
        if state.started || state.startDate <= Date() {
            Text("Now")
        } else {
            Text(timerInterval: Date()...state.startDate, countsDown: true, showsHours: false)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

struct EventIcon: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "calendar").font(.system(size: size * 0.5)).foregroundStyle(Theme.accent)
            .frame(width: size, height: size).background(Theme.accent.opacity(0.15), in: Circle())
    }
}

/// Fills from when the countdown began to the start, by itself.
struct EventBar: View {
    let state: EventActivityAttributes.ContentState

    var body: some View {
        if let since = state.sinceDate, since < state.startDate, !state.started {
            ProgressView(timerInterval: since...state.startDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(Theme.accent)
        }
    }
}

/// The notes (or where), and what comes next.
struct EventDetails: View {
    let state: EventActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if let notes = state.notes {
                Label(notes, systemImage: "text.alignleft").lineLimit(1)
            } else if let place = state.place {
                Label(place, systemImage: "mappin.and.ellipse").lineLimit(1)
            } else {
                Label(times, systemImage: "clock")
            }
            Spacer(minLength: 0)
            if let then = state.then {
                (Text("then ") + Text(then.title).foregroundColor(.primary) + Text(" ")
                    + Text(then.startDate, style: .time))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .lineLimit(1)
    }

    private var times: String {
        let start = state.startDate.formatted(date: .omitted, time: .shortened)
        guard let end = state.endDate else { return start }
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct EventLockScreen: View {
    let attributes: EventActivityAttributes
    let state: EventActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                EventIcon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.title).font(.headline).lineLimit(1)
                    Text(Self.subtitle(attributes, state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    EventCountdown(state: state).font(.title2.weight(.bold))
                    Text(state.startDate, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            EventBar(state: state)
            EventDetails(state: state).font(.caption.weight(.medium))
        }
        .padding(16)
    }

    /// "Aula 5 · 1 h", or the calendar's name without a place; "Started" once it's on.
    static func subtitle(_ attributes: EventActivityAttributes, _ state: EventActivityAttributes.ContentState) -> String {
        if state.started { return "Started" }
        let place = state.notes != nil ? state.place : nil  // without notes, the place is on the row below
        return [place ?? attributes.calendar, state.length].compactMap { $0 }.joined(separator: " · ")
    }
}
