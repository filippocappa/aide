import ActivityKit
import SwiftUI
import WidgetKit

/// A tram alert's countdown on the Lock Screen and in the Dynamic Island (docs/API.md, "Live Activities").
struct TramLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TramActivityAttributes.self) { context in
            TramLockScreen(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Theme.background)
                .widgetURL(URL(string: "aide://agent/secretary"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LineBadge(line: a.line, vehicle: a.vehicle, compact: true).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TramCountdown(state: s).font(.title3.weight(.bold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(a.towards.map { "to \($0)" } ?? a.stop).font(.subheadline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        TramTrack(state: s, color: LineBadge(line: a.line, vehicle: a.vehicle).color)
                        TramDetails(attributes: a, state: s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                LineBadge(line: a.line, vehicle: a.vehicle, compact: true)
            } compactTrailing: {
                TramCountdown(state: s).font(.caption.weight(.bold)).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "tram.fill").foregroundStyle(LineBadge(line: a.line, vehicle: a.vehicle).color)
            }
            .widgetURL(URL(string: "aide://agent/secretary"))
            .keylineTint(LineBadge(line: a.line, vehicle: a.vehicle).color)
        }
    }
}

/// Minutes to the tram, counting down by itself; "Gone" once it has left.
struct TramCountdown: View {
    let state: TramActivityAttributes.ContentState

    var body: some View {
        if state.gone || state.atDate <= Date() {
            Text(state.gone ? "Gone" : "Now")
        } else {
            Text(timerInterval: Date()...state.atDate, countsDown: true, showsHours: false)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

/// When to leave, the walk, live (or timetable, or GTT's feed down), and the next one.
struct TramDetails: View {
    let attributes: TramActivityAttributes
    let state: TramActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if let leave = state.leaveDate, !state.gone {
                if leave > Date() {
                    Label { Text("Leave in ") + Text(leave, style: .timer) } icon: { Image(systemName: "figure.walk") }
                } else {
                    Label("Leave now", systemImage: "figure.walk").foregroundStyle(.orange)
                }
            } else if let walk = state.walk {
                Label("\(max(1, walk / 60)) min walk", systemImage: "figure.walk")
            }
            Spacer(minLength: 0)
            if state.live {
                Label(delayText, systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(state.delay ?? 0 > 60 ? .orange : .green)
            } else if state.feedDown == true {
                Label("GTT live down", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Text("Timetable").foregroundStyle(.secondary)
            }
            if let next = state.nextDate {
                Text("then \(next.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }

    private var delayText: String {
        guard let delay = state.delay, abs(delay) >= 60 else { return "On time" }
        return delay > 0 ? "\(delay / 60) min late" : "\(-delay / 60) min early"
    }
}

/// Where the tram is: a dot per stop it has still to reach (up to 5), then yours, with a line on what it's near.
struct TramTrack: View {
    let state: TramActivityAttributes.ContentState
    let color: Color

    private static let shown = 5

    var body: some View {
        if let stops = state.stops, !state.gone {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Capsule().fill(.secondary.opacity(0.35)).frame(height: 2)
                    HStack(spacing: 0) {
                        Image(systemName: "tram.fill").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(4).background(color, in: Circle())
                        if stops > Self.shown {
                            Spacer(minLength: 2)
                            Text("···").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        ForEach(0..<min(stops, Self.shown), id: \.self) { _ in
                            Spacer(minLength: 2)
                            Circle().fill(.secondary).frame(width: 6, height: 6)
                        }
                        Spacer(minLength: 2)
                        Circle().strokeBorder(color, lineWidth: 3).frame(width: 14, height: 14)
                            .background(Circle().fill(.background))
                    }
                }
                Text(caption(stops)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func caption(_ stops: Int) -> String {
        let away = stops == 0 ? "Your stop is next" : "\(stops) stop\(stops == 1 ? "" : "s") away"
        guard let near = state.near else { return away }
        if let starts = state.startsDate {
            return "\(away) · leaves \(near) at \(starts.formatted(date: .omitted, time: .shortened))"
        }
        return "\(away) · near \(near)"
    }
}

struct TramLockScreen: View {
    let attributes: TramActivityAttributes
    let state: TramActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LineBadge(line: attributes.line, vehicle: attributes.vehicle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.towards.map { "to \($0)" } ?? attributes.vehicle).font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(attributes.stop) · \(attributes.code)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    TramCountdown(state: state).font(.title2.weight(.bold))
                    Text(state.atDate, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            TramTrack(state: state, color: LineBadge(line: attributes.line, vehicle: attributes.vehicle).color)
            TramDetails(attributes: attributes, state: state)
            if stale && !state.gone {
                Text("Not updated for a while: times may be off.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
