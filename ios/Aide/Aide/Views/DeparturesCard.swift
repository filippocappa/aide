import SwiftUI

/// A stop's next trams and buses (docs/API.md, "Departures"): line, direction, minutes, live or timetable, how late,
/// the walk from the phone and when to leave, and where it gets you when Aide knows where you're going. While it's on
/// screen the minutes count down, and the board is fetched again every 30 seconds for the latest live times.
struct DeparturesCard: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var board: DepartureBoard

    /// Seconds between refreshes while on screen.
    static let refreshEvery: Duration = .seconds(30)
    /// An older card (an old chat) stays as it was.
    static let liveFor: TimeInterval = 3 * 3600
    /// On top of the walk, as the server's leave-now alerts do.
    static let buffer: TimeInterval = 120

    init(board: DepartureBoard) {
        _board = State(initialValue: board)
    }

    private var isLive: Bool {
        guard let made = board.madeDate else { return false }
        return Date().timeIntervalSince(made) < Self.liveFor
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            content(now: isLive ? context.date : board.madeDate ?? context.date)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: board.id) { await keepLive() }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            let lines = board.lines.compactMap { line -> (DepartureBoard.Line, [DepartureBoard.Arrival])? in
                let coming = line.arrivals.filter { ($0.date ?? .distantPast) > now.addingTimeInterval(-30) }
                return coming.isEmpty ? nil : (line, coming)
            }
            if lines.isEmpty {
                Text(board.to.map { "Nothing goes to \($0.name) directly in the next hour." } ?? "Nothing in the next hour.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.0.id) { line, coming in
                Divider()
                LineRow(line: line, arrivals: coming, walk: board.walk.map(TimeInterval.init), destination: board.to?.name,
                        now: now)
            }
            if !isLive, let made = board.madeDate {
                Text("As of \(made.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(board.stop.name).font(.headline)
                    Text("stop \(board.stop.code)").font(.caption).foregroundStyle(.secondary)
                }
                if let to = board.to {
                    Label("to \(to.name)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let walk = board.walk {
                Label("\(max(1, Int((Double(walk) / 60).rounded()))) min", systemImage: "figure.walk")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(Int((Double(walk) / 60).rounded())) minute walk")
            }
        }
    }

    private func keepLive() async {
        while !Task.isCancelled && isLive {
            try? await Task.sleep(for: Self.refreshEvery)
            guard !Task.isCancelled, isLive else { return }
            if let fresh = try? await env.api.departures(board) {
                withAnimation(.snappy) { board = fresh }
            }
        }
    }
}

/// One line in one direction: the badge, where it's going, whether it's live and late, the minutes, the ones after,
/// when it gets you there, and when to leave.
private struct LineRow: View {
    let line: DepartureBoard.Line
    let arrivals: [DepartureBoard.Arrival]
    let walk: TimeInterval?
    let destination: String?
    let now: Date

    private var first: DepartureBoard.Arrival { arrivals[0] }

    private func seconds(_ a: DepartureBoard.Arrival) -> TimeInterval { (a.date ?? now).timeIntervalSince(now) }
    private func minutes(_ a: DepartureBoard.Arrival) -> Int { max(0, Int((seconds(a) / 60).rounded())) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LineBadge(line: line.line, vehicle: line.vehicle)
            VStack(alignment: .leading, spacing: 3) {
                if let towards = line.towards, !towards.isEmpty {
                    Text("→ \(towards)").font(.subheadline.weight(.medium)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    status(first)
                    if arrivals.count > 1 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("then " + arrivals.dropFirst().prefix(2).map { "\(minutes($0))" }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                if destination != nil, let there = first.arrivesDate {
                    let ride = max(1, Int((there.timeIntervalSince(first.date ?? there) / 60).rounded()))
                    Label("there at \(there.formatted(date: .omitted, time: .shortened)), \(ride) min ride",
                          systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(.secondary)
                }
                leave
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                if seconds(first) < 45 {
                    Text("now").font(.title2.weight(.bold)).foregroundStyle(Self.live)
                } else {
                    Text("\(minutes(first))").font(.title.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("min").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .opacity(catchable(first) ? 1 : 0.45)
        }
        .accessibilityElement(children: .combine)
    }

    static let live = Color(red: 0.15, green: 0.68, blue: 0.36)
    static let late = Color(red: 0.89, green: 0.45, blue: 0.13)

    @ViewBuilder
    private func status(_ a: DepartureBoard.Arrival) -> some View {
        if a.live {
            let late = Int((Double(a.delay ?? 0) / 60).rounded())
            LiveDot()
            Text(late > 0 ? "\(late) min late" : late < 0 ? "\(-late) min early" : "on time")
                .foregroundStyle(late > 1 ? Self.late : Self.live)
        } else {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("timetable").foregroundStyle(.secondary)
        }
    }

    /// A tram closer than the walk can't be caught.
    private func catchable(_ a: DepartureBoard.Arrival) -> Bool {
        guard let walk else { return true }
        return seconds(a) >= walk
    }

    /// For the first tram you can still catch: leave now, or in so many minutes.
    @ViewBuilder
    private var leave: some View {
        if let walk, let next = arrivals.first(where: catchable) {
            let spare = seconds(next) - walk - DeparturesCard.buffer
            let which = next == first ? "" : " for the one in \(minutes(next))"
            if spare <= 0 {
                Label("Leave now" + which, systemImage: "figure.walk.motion")
                    .font(.caption.weight(.semibold)).foregroundStyle(Self.late)
            } else if spare < 20 * 60 {
                Label("Leave in \(max(1, Int((spare / 60).rounded()))) min" + which, systemImage: "figure.walk")
                    .font(.caption.weight(.medium)).foregroundStyle(.primary)
            }
        }
    }
}

/// The line's number on a tram, bus or metro badge.
struct LineBadge: View {
    let line: String
    let vehicle: String

    private var symbol: String {
        switch vehicle {
        case "Tram": "tram.fill"
        case "Metro": "tram.fill.tunnel"
        case "Train": "train.side.front.car"
        default: "bus.fill"
        }
    }

    private var color: Color {
        switch vehicle {
        case "Tram": Color(red: 0.91, green: 0.47, blue: 0.16)
        case "Metro": Color(red: 0.78, green: 0.11, blue: 0.18)
        case "Train": Color(red: 0.30, green: 0.36, blue: 0.42)
        default: Color(red: 0.16, green: 0.42, blue: 0.71)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(line).font(.subheadline.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 54)
        .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vehicle) \(line)")
    }
}

/// A small green dot that breathes: these minutes are live from GTT.
private struct LiveDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(LineRow.live)
            .frame(width: 7, height: 7)
            .background(Circle().fill(LineRow.live.opacity(0.35)).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityHidden(true)
    }
}
