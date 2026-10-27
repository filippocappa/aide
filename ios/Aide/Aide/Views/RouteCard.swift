import SwiftUI

/// How long it takes to get somewhere (docs/API.md, Chat, `routes`): the way there, the time with traffic against the
/// usual, the distance, when you'd leave and get there, the rides on a transit route, and buttons to open it in Maps.
struct RouteCard: View {
    let route: TravelRoute
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let traffic {
                traffic
            }
            if !route.rides.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(route.rides.enumerated()), id: \.offset) { _, ride in
                        RideRow(ride: ride)
                    }
                }
            }
            times
            HStack(spacing: 8) {
                mapsButton("Google Maps", systemImage: "map.fill", url: URL(string: route.url), primary: true)
                mapsButton("Apple Maps", systemImage: "applelogo", url: appleMaps, primary: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 42, height: 42)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(route.to).font(.headline).lineLimit(2)
                Text("\(modeName) from \(route.from)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Self.duration(route.duration)).font(.title2.weight(.bold)).monospacedDigit()
                Text(Self.distance(route.distance)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Driving: how the traffic changes it.
    private var traffic: AnyView? {
        guard route.mode == "drive" else { return nil }
        guard let usual = route.usual, abs(route.duration - usual) >= 120 else {
            return AnyView(Label("Live traffic, as usual", systemImage: "car.side")
                .font(.caption.weight(.medium)).foregroundStyle(Self.good))
        }
        let slower = route.duration > usual
        return AnyView(Label("\(Self.duration(abs(route.duration - usual))) \(slower ? "slower" : "faster") than usual "
                             + "(\(Self.duration(usual)))",
                             systemImage: slower ? "exclamationmark.triangle.fill" : "hare.fill")
            .font(.caption.weight(.medium)).foregroundStyle(slower ? Self.slow : Self.good))
    }

    @ViewBuilder
    private var times: some View {
        if let depart = route.departDate, let arrive = route.arriveDate {
            HStack(spacing: 6) {
                Label(route.mode == "transit" ? "First ride \(Self.clock(depart))" : "Leave \(Self.clock(depart))",
                      systemImage: "figure.walk.departure")
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Label("there \(Self.clock(arrive))", systemImage: "flag.checkered")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func mapsButton(_ title: String, systemImage: String, url: URL?, primary: Bool) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(primary ? Theme.onAccent : Theme.accent)
                .background(primary ? Theme.accent : Theme.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    /// The same way in Apple Maps; from where the phone is unless the route started somewhere else.
    private var appleMaps: URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        let flag = ["drive": "d", "walk": "w", "transit": "r", "bicycle": "c"][route.mode] ?? "d"
        var items = [URLQueryItem(name: "daddr", value: route.to), URLQueryItem(name: "dirflg", value: flag)]
        if route.from != "where you are" { items.append(URLQueryItem(name: "saddr", value: route.from)) }
        parts?.queryItems = items
        return parts?.url
    }

    private var symbol: String {
        switch route.mode {
        case "walk": "figure.walk"
        case "bicycle": "bicycle"
        case "transit": "tram.fill"
        default: "car.fill"
        }
    }

    private var modeName: String {
        switch route.mode {
        case "walk": "Walking"
        case "bicycle": "Cycling"
        case "transit": "Transit"
        default: "Driving"
        }
    }

    static let good = Color(red: 0.15, green: 0.68, blue: 0.36)
    static let slow = Color(red: 0.89, green: 0.45, blue: 0.13)

    static func duration(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func distance(_ metres: Int) -> String {
        metres < 1000 ? "\(metres) m" : String(format: "%.1f km", Double(metres) / 1000)
    }

    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// One ride: the line's badge, where it's heading, and from where and when to where and when.
private struct RideRow: View {
    let ride: TravelRoute.Ride

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LineBadge(line: ride.line ?? "?", vehicle: ride.vehicle)
            VStack(alignment: .leading, spacing: 3) {
                if let towards = ride.towards, !towards.isEmpty {
                    Text("→ \(towards)").font(.subheadline.weight(.medium)).lineLimit(1)
                }
                stop(ride.departDate, ride.from, systemImage: "circle")
                stop(ride.arriveDate, ride.to, systemImage: "smallcircle.filled.circle")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stop(_ date: Date?, _ name: String?, systemImage: String) -> some View {
        if date != nil || name != nil {
            Label {
                Text([date.map(RouteCard.clock), name].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            } icon: {
                Image(systemName: systemImage).font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
