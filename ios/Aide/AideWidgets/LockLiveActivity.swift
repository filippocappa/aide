import ActivityKit
import SwiftUI
import WidgetKit

/// A Screen Time lock while it holds (docs/API.md, "Live Activities", `lock`): Pebble asleep, the time left counting
/// down to when it opens, and a bar from when it came on. "Open" once it's over, for the moment it stays up.
struct LockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockActivityAttributes.self) { context in
            LockLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.background)
                .widgetURL(URL(string: "aide://screen"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LockPebble(state: s, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        LockCountdown(state: s).font(.title2.weight(.bold))
                        Text("left").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(.headline).lineLimit(1)
                        Text(LockLockScreen.subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LockBar(state: s).padding(.horizontal, 4)
                }
            } compactLeading: {
                LockPebble(state: s, size: 22, plain: true)
            } compactTrailing: {
                LockCountdown(state: s).font(.caption.weight(.bold)).frame(maxWidth: 56)
            } minimal: {
                LockPebble(state: s, size: 22, plain: true)
            }
            .widgetURL(URL(string: "aide://screen"))
            .keylineTint(Theme.accent)
        }
    }
}

/// The time left, counting down by itself ("1:42:10", "12:05"); "Open" once it's over.
struct LockCountdown: View {
    let state: LockActivityAttributes.ContentState

    var body: some View {
        if state.over || state.untilDate <= Date() {
            Text("Open")
        } else {
            Text(timerInterval: Date()...state.untilDate, countsDown: true, showsHours: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

/// Pebble asleep while the lock holds, awake once it's open; on a disc except in the island's small spots.
struct LockPebble: View {
    let state: LockActivityAttributes.ContentState
    var size: CGFloat = 36
    var plain = false

    var body: some View {
        let mark = FigureShape(figure: .pebble, face: state.over ? "calm" : "sleeping", scale: 1)
            .shaded()
            .foregroundStyle(Theme.accent)
        if plain {
            mark.frame(width: size, height: size)
        } else {
            mark.frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size).background(Theme.accent.opacity(0.15), in: Circle())
        }
    }
}

/// Fills from when the lock came on to when it opens, by itself.
struct LockBar: View {
    let state: LockActivityAttributes.ContentState

    var body: some View {
        if !state.over, state.sinceDate < state.untilDate {
            ProgressView(timerInterval: state.sinceDate...state.untilDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(Theme.accent)
        }
    }
}

struct LockLockScreen: View {
    let attributes: LockActivityAttributes
    let state: LockActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LockPebble(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.title).font(.headline).lineLimit(1)
                    Text(Self.subtitle(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                LockCountdown(state: state).font(.title2.weight(.bold))
            }
            LockBar(state: state)
        }
        .padding(16)
    }

    /// "Locked until 07:00 · Strict", or "Open" once it's over.
    static func subtitle(_ state: LockActivityAttributes.ContentState) -> String {
        if state.over { return "Open again" }
        let until = "Locked until " + state.untilDate.formatted(date: .omitted, time: .shortened)
        return state.strict ? until + " · Strict" : until
    }
}
