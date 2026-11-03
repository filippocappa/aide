import ActivityKit
import SwiftUI
import WidgetKit

/// A focus session (docs/API.md, "Live Activities", `focus`): Professor focused or resting, the phase and the time
/// left in it, the topic, "Round 2 of 4", and a bar through the phase. Study's colour in a round, calm in a break.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.background)
                .widgetURL(URL(string: "aide://study"))
        } dynamicIsland: { context in
            let s = context.state, a = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FocusMark(state: s, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        FocusCountdown(state: s).font(.title2.weight(.bold))
                        Text(FocusLockScreen.left(s)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(FocusLockScreen.title(s)).font(.headline).lineLimit(1)
                        Text(FocusLockScreen.subtitle(a, s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    FocusBar(state: s).padding(.horizontal, 4)
                }
            } compactLeading: {
                FocusMark(state: s, size: 22, plain: true)
            } compactTrailing: {
                FocusCountdown(state: s).font(.caption.weight(.bold)).frame(maxWidth: 56)
            } minimal: {
                FocusMark(state: s, size: 22, plain: true)
            }
            .widgetURL(URL(string: "aide://study"))
            .keylineTint(Theme.study)
        }
    }
}

/// The time left in the phase, counting down by itself; "Done" at the end.
struct FocusCountdown: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        if state.over {
            Text("Done")
        } else if state.endsDate <= Date() {
            Text("0:00")
        } else {
            Text(timerInterval: Date()...state.endsDate, countsDown: true, showsHours: false)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

/// Professor's dome: thinking in a round, glad in a break and at the end.
struct FocusMark: View {
    let state: FocusActivityAttributes.ContentState
    var size: CGFloat = 36
    var plain = false

    private var face: String { state.isFocus && !state.over ? "thinking" : "happy" }
    private var tint: Color { state.isFocus || state.over ? Theme.study : .mint }

    var body: some View {
        let mark = FigureShape(figure: .dome, face: face, scale: 1).shaded().foregroundStyle(tint)
        if plain {
            mark.frame(width: size, height: size)
        } else {
            mark.frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size).background(tint.opacity(0.2), in: Circle())
        }
    }
}

/// Fills through the phase, by itself.
struct FocusBar: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        if !state.over, state.sinceDate < state.endsDate {
            ProgressView(timerInterval: state.sinceDate...state.endsDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(state.isFocus ? Theme.study : .mint)
        }
    }
}

struct FocusLockScreen: View {
    let attributes: FocusActivityAttributes
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FocusMark(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(state)).font(.headline).lineLimit(1)
                    Text(Self.subtitle(attributes, state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    FocusCountdown(state: state).font(.title2.weight(.bold))
                    Text(Self.left(state)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            FocusBar(state: state)
        }
        .padding(16)
    }

    /// "Focus · round 2 of 4", "Break", "Focus done".
    static func title(_ s: FocusActivityAttributes.ContentState) -> String {
        if s.over { return "Focus done" }
        if s.isFocus { return s.rounds == 1 ? "Focus" : "Focus · round \(s.round) of \(s.rounds)" }
        return "Break · round \(s.round) of \(s.rounds) done"
    }

    /// The topic (else the course), then the minutes so far once there are some.
    static func subtitle(_ a: FocusActivityAttributes, _ s: FocusActivityAttributes.ContentState) -> String {
        let what = a.topic.isEmpty ? a.title : a.topic
        if s.over { return "\(what) · \(s.minutes) min of focus" }
        return s.minutes > 0 ? "\(what) · \(s.minutes) min so far" : what
    }

    static func left(_ s: FocusActivityAttributes.ContentState) -> String {
        s.over ? "" : s.isFocus ? "to the break" : "to round \(s.round + 1)"
    }
}
