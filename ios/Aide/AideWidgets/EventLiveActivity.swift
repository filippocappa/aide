import ActivityKit
import SwiftUI
import WidgetKit

/// The next calendar event, counting down from 30 minutes before (docs/API.md, "Live Activities").
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
                    Image(systemName: "calendar").font(.title2).foregroundStyle(Theme.accent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EventCountdown(state: s).font(.title3.weight(.bold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(a.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EventDetails(state: s).font(.caption.weight(.medium)).padding(.horizontal, 4)
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

/// Where, and from when to when.
struct EventDetails: View {
    let state: EventActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if let place = state.place {
                Label(place, systemImage: "mappin.and.ellipse").lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(times).foregroundStyle(.secondary).fixedSize()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "calendar").font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36).background(Theme.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(state.started ? "Started" : attributes.calendar).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EventCountdown(state: state).font(.title2.weight(.bold))
            }
            EventDetails(state: state).font(.caption.weight(.medium))
        }
        .padding(16)
    }
}
