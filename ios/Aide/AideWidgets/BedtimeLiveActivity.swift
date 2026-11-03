import ActivityKit
import SwiftUI
import WidgetKit

/// The evening's countdown to bedtime (docs/API.md, "Live Activities", `bedtime`): Pebble getting sleepy, the time
/// left to be in bed, the wake time it's worked back from, and a bar from the nudge to bedtime. Sleep's indigo.
struct BedtimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BedtimeActivityAttributes.self) { context in
            BedtimeLockScreen(state: context.state)
                .activityBackgroundTint(Theme.background)
                .widgetURL(URL(string: "aide://settings/bedtime"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BedtimePebble(state: s, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        BedtimeCountdown(state: s).font(.title2.weight(.bold))
                        Text("to bed").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BedtimeLockScreen.title(s)).font(.headline).lineLimit(1)
                        Text(BedtimeLockScreen.subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    BedtimeBar(state: s).padding(.horizontal, 4)
                }
            } compactLeading: {
                BedtimePebble(state: s, size: 22, plain: true)
            } compactTrailing: {
                BedtimeCountdown(state: s).font(.caption.weight(.bold)).frame(maxWidth: 56)
            } minimal: {
                BedtimePebble(state: s, size: 22, plain: true)
            }
            .widgetURL(URL(string: "aide://settings/bedtime"))
            .keylineTint(ScoreColors.sleep[1])
        }
    }
}

/// The time left to bedtime, counting down by itself ("42:10"); "Now" once it's come.
struct BedtimeCountdown: View {
    let state: BedtimeActivityAttributes.ContentState

    var body: some View {
        if state.over || state.bedtimeDate <= Date() {
            Text("Now")
        } else {
            Text(timerInterval: Date()...state.bedtimeDate, countsDown: true, showsHours: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

/// Pebble asleep, in sleep's indigo; on a disc except in the island's small spots.
struct BedtimePebble: View {
    let state: BedtimeActivityAttributes.ContentState
    var size: CGFloat = 36
    var plain = false

    var body: some View {
        let mark = FigureShape(figure: .pebble, face: "sleeping", scale: 1)
            .shaded()
            .foregroundStyle(ScoreColors.sleep[0])
        if plain {
            mark.frame(width: size, height: size)
        } else {
            mark.frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size).background(ScoreColors.sleep[1].opacity(0.2), in: Circle())
        }
    }
}

/// Fills from the nudge to bedtime, by itself.
struct BedtimeBar: View {
    let state: BedtimeActivityAttributes.ContentState

    var body: some View {
        if !state.over, state.sinceDate < state.bedtimeDate {
            ProgressView(timerInterval: state.sinceDate...state.bedtimeDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(ScoreColors.sleep[0])
        }
    }
}

struct BedtimeLockScreen: View {
    let state: BedtimeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BedtimePebble(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(state)).font(.headline).lineLimit(1)
                    Text(Self.subtitle(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                BedtimeCountdown(state: state).font(.title2.weight(.bold))
            }
            BedtimeBar(state: state)
        }
        .padding(16)
    }

    /// "Bed at 23:10", or "Time for bed" once it's come.
    static func title(_ state: BedtimeActivityAttributes.ContentState) -> String {
        state.over ? "Time for bed" : "Bed at " + state.bedtimeDate.formatted(date: .omitted, time: .shortened)
    }

    /// "7h30 of sleep · up at 7:15"
    static func subtitle(_ state: BedtimeActivityAttributes.ContentState) -> String {
        let h = state.need_min / 60, m = state.need_min % 60
        let need = m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
        return "\(need) of sleep · up at " + state.wakeDate.formatted(date: .omitted, time: .shortened)
    }
}
