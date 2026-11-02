#if os(iOS)
import FamilyControls
import ManagedSettings
#else
import AppKit
#endif
import SwiftUI

/// What the report hands its view: the days read (the period and what it's compared with) and the period itself.
struct UsageReportData {
    let kind: UsageKind
    let days: [UsageDay]
    let period: DateInterval
    /// The phone shown, when other devices sharing Screen Time were left out (`leftOut`).
    var device: String? = nil
    var leftOut: [String] = []
}

/// The Screen tab's page under the switch and the date: the total (every app's time added up), the focus score, the
/// hours or days as bars, and the apps, most used first. Drawn by the UsageReport extension, the only place iOS lets
/// an app see this; the app draws it from sample data for Simulator screenshots. It can't use the app's `Theme`, so
/// its few colours are here.
struct UsageReportView: View {
    let data: UsageReportData
    var now = Date()
    @State private var showFocus = false
    @State private var openApp: String?
    @State private var showAll = false
    @State private var openSite: String?
    @State private var showAllSites = false

    private var calendar: Calendar { .current }
    private var periodDays: [UsageDay] {
        UsageMath.days(of: data.period).map { date in data.days.first { $0.date == date } ?? UsageDay(date: date) }
    }
    private var begun: [UsageDay] { periodDays.filter { $0.date <= now } }
    private var day: UsageDay { periodDays.last ?? UsageDay(date: data.period.start) }
    private var apps: [UsageApp] { data.kind == .day ? day.ranked : UsageMath.merged(periodDays) }
    private var total: TimeInterval { apps.reduce(0) { $0 + $1.seconds } }
    /// The websites (the Mac only), part of their browsers' time.
    private var sites: [UsageSite] { data.kind == .day ? day.sites : UsageMath.mergedSites(periodDays) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summary
                if total >= 60 { mostUsed }
                if total >= 60, !sites.isEmpty { websites }
                if let device = data.device, !data.leftOut.isEmpty {
                    Text("Only \(device). Screen Time from \(data.leftOut.joined(separator: ", ")) is left out.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // MARK: The summary card

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.kind == .day ? "All your apps, added up" : "A day, on average")
                        .font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(UsageMath.duration(headline))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    if let line = comparison {
                        Label(line.text, systemImage: line.under ? "arrow.down" : "arrow.up")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(line.under ? UsageColors.good : UsageColors.over)
                    }
                    #if DEBUG
                    if data.kind == .day, day.reported > 0 {
                        // A check against Settings → Screen Time: the apps as iOS hands them over, and its own total.
                        Text("Apps \(UsageMath.duration(day.added)) · iOS \(UsageMath.duration(day.reported))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    #endif
                }
                Spacer(minLength: 0)
                if let focus {
                    Button { withAnimation(.snappy) { showFocus.toggle() } } label: {
                        FocusRing(score: focus.score)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Focus \(focus.score), what it's made of")
                }
            }
            if showFocus, let focus { FocusParts(focus: focus, kind: data.kind) }
            stats
            bars
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The day's total, or the average a day over the days of the period that have begun.
    private var headline: TimeInterval {
        data.kind == .day ? total : (UsageMath.average(begun, now: now) ?? 0)
    }

    private var comparison: (text: String, under: Bool)? {
        switch data.kind {
        case .day:
            let time = UsageMath.timeOfDay(day, now: now)
            guard let usual = UsageMath.usual(before: day, in: data.days, by: time) else { return nil }
            let diff = total - usual
            guard abs(diff) >= 60 else { return ("Same as your usual", true) }
            let when = time == nil ? "" : " by now"
            return ("\(UsageMath.duration(abs(diff))) \(diff < 0 ? "under" : "over") your usual\(when)", diff < 0)
        case .week, .month:
            let before = data.days.filter { $0.date < data.period.start }
            guard before.contains(where: { $0.total > 0 }), begun.contains(where: { $0.date < calendar.startOfDay(for: now) }),
                  let was = UsageMath.average(before, now: now) else { return nil }
            let diff = headline - was
            let last = data.kind == .week ? "last week" : "last month"
            guard abs(diff) >= 60 else { return ("Same as \(last)", true) }
            return ("\(UsageMath.duration(abs(diff))) a day \(diff < 0 ? "under" : "over") \(last)", diff < 0)
        }
    }

    /// The day's focus; for a week or month, the average of its days' (each against its own usual).
    private var focus: UsageMath.Focus? {
        if data.kind == .day { return total > 0 ? UsageMath.focus(day, in: data.days, now: now) : nil }
        let scored = begun.filter { $0.total > 0 }.map { UsageMath.focus($0, in: data.days, now: now) }
        guard !scored.isEmpty else { return nil }
        let score = Int((Double(scored.reduce(0) { $0 + $1.score }) / Double(scored.count)).rounded())
        return UsageMath.Focus(score: score, parts: [])
    }

    private var stats: some View {
        HStack(spacing: 0) {
            ForEach(Array(statItems.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.headline.monospacedDigit())
                    Text(item.1).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : 12)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(UsageColors.line).frame(width: 1) }
                }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(UsageColors.line).frame(height: 1) }
    }

    private var statItems: [(String, String)] {
        switch data.kind {
        case .day:
            var items = [("\(day.pickups)", "pickups")]
            items.append((day.firstPickup.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–", "first pickup"))
            items.append((UsageMath.offline(day, now: now).map(UsageMath.duration) ?? "–", "offline"))
            return items
        case .week, .month:
            let counted = UsageMath.averaged(begun, now: now)
            let pickups = counted.reduce(0) { $0 + $1.pickups } / max(1, counted.count)
            let least = begun.filter { $0.date < calendar.startOfDay(for: now) }.min { $0.total < $1.total }
            return [(UsageMath.duration(begun.reduce(0) { $0 + $1.total }), "in all"),
                    ("\(pickups)", "pickups a day"),
                    (least.map { $0.date.formatted(.dateTime.weekday(.abbreviated).day()) } ?? "–", "least")]
        }
    }

    // MARK: Bars

    @ViewBuilder private var bars: some View {
        switch data.kind {
        case .day:
            UsageBars(values: day.hourly, now: currentHour, labels: ["00", "06", "12", "18", "24"])
        case .week:
            UsageBars(values: periodDays.map(\.total), now: currentDayIndex,
                      labels: periodDays.map { $0.date.formatted(.dateTime.weekday(.narrow)) },
                      average: UsageMath.average(begun, now: now), labelsUnder: true)
        case .month:
            UsageBars(values: periodDays.map(\.total), now: currentDayIndex, labels: ["1", "8", "15", "22", "29"],
                      average: UsageMath.average(begun, now: now))
        }
    }

    private var currentHour: Int? {
        UsageMath.timeOfDay(day, now: now).map { Int($0 / 3600) }
    }

    private var currentDayIndex: Int? {
        periodDays.firstIndex { calendar.isDate($0.date, inSameDayAs: now) }
    }

    // MARK: Most used

    private var mostUsed: some View {
        let shown = showAll ? apps : Array(apps.prefix(8))
        let rest = apps.dropFirst(8)
        let top = apps.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Most used").font(.headline)
                Spacer()
                Text("\(apps.count) app\(apps.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                VStack(spacing: 0) {
                    if index > 0 { Rectangle().fill(UsageColors.line).frame(height: 1).padding(.leading, 44) }
                    Button { withAnimation(.snappy) { openApp = openApp == app.id ? nil : app.id } } label: {
                        AppRow(app: app, share: app.seconds / top, average: data.kind == .day ? nil : app.seconds / Double(max(1, begun.count)))
                    }
                    .buttonStyle(.plain)
                    if openApp == app.id { appDetail(app) }
                }
            }
            if !rest.isEmpty {
                Rectangle().fill(UsageColors.line).frame(height: 1)
                Button { withAnimation(.snappy) { showAll.toggle() } } label: {
                    HStack {
                        Text(showAll ? "Show fewer" : "\(rest.count) other app\(rest.count == 1 ? "" : "s")")
                        Spacer()
                        if !showAll {
                            Text(UsageMath.duration(rest.reduce(0) { $0 + $1.seconds })).foregroundStyle(.secondary)
                        }
                        Image(systemName: showAll ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, rest.isEmpty ? 6 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// One app, opened: its hours (a day) or days (a week or month), its pickups and notifications.
    private func appDetail(_ app: UsageApp) -> some View {
        let values: [TimeInterval] = data.kind == .day ? (app.hourly.count == 24 ? app.hourly : [])
            : periodDays.map { d in d.apps.first { $0.id == app.id }?.seconds ?? 0 }
        let labels: [String] = switch data.kind {
        case .day: ["00", "06", "12", "18", "24"]
        case .week: periodDays.map { $0.date.formatted(.dateTime.weekday(.narrow)) }
        case .month: ["1", "8", "15", "22", "29"]
        }
        return VStack(alignment: .leading, spacing: 10) {
            if !values.isEmpty, values.contains(where: { $0 > 0 }) {
                UsageBars(values: values, now: data.kind == .day ? currentHour : currentDayIndex, labels: labels,
                          height: 56, labelsUnder: data.kind == .week)
            }
            Text(appLine(app)).font(.footnote).foregroundStyle(.secondary)
            let inBrowser = sites.compactMap { site in site.browsers[app.id].map { (site.id, $0) } }
                .filter { $0.1 >= 30 }.sorted { $0.1 > $1.1 }.prefix(5)
            if !inBrowser.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(inBrowser), id: \.0) { site, seconds in
                        HStack {
                            Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                            Text(site).lineLimit(1)
                            Spacer()
                            Text(UsageMath.duration(seconds)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .padding(.leading, 44)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    // MARK: Websites

    private var websites: some View {
        let shown = showAllSites ? sites : Array(sites.prefix(6))
        let rest = sites.dropFirst(6)
        let top = sites.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Websites").font(.headline)
                Spacer()
                Text("in your browsers").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, site in
                VStack(spacing: 0) {
                    if index > 0 { Rectangle().fill(UsageColors.line).frame(height: 1).padding(.leading, 44) }
                    Button { withAnimation(.snappy) { openSite = openSite == site.id ? nil : site.id } } label: {
                        SiteRow(site: site, share: site.seconds / top,
                                average: data.kind == .day ? nil : site.seconds / Double(max(1, begun.count)))
                    }
                    .buttonStyle(.plain)
                    if openSite == site.id { siteDetail(site) }
                }
            }
            if !rest.isEmpty {
                Rectangle().fill(UsageColors.line).frame(height: 1)
                Button { withAnimation(.snappy) { showAllSites.toggle() } } label: {
                    HStack {
                        Text(showAllSites ? "Show fewer" : "\(rest.count) other website\(rest.count == 1 ? "" : "s")")
                        Spacer()
                        if !showAllSites {
                            Text(UsageMath.duration(rest.reduce(0) { $0 + $1.seconds })).foregroundStyle(.secondary)
                        }
                        Image(systemName: showAllSites ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, rest.isEmpty ? 6 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// One website, opened: its hours or days, and which browsers it was in.
    private func siteDetail(_ site: UsageSite) -> some View {
        let values: [TimeInterval] = data.kind == .day ? (site.hourly.count == 24 ? site.hourly : [])
            : periodDays.map { d in d.sites.first { $0.id == site.id }?.seconds ?? 0 }
        let labels: [String] = switch data.kind {
        case .day: ["00", "06", "12", "18", "24"]
        case .week: periodDays.map { $0.date.formatted(.dateTime.weekday(.narrow)) }
        case .month: ["1", "8", "15", "22", "29"]
        }
        let browsers = site.browsers.sorted { $0.value > $1.value }.map { id, seconds in
            "\(apps.first { $0.id == id }?.name ?? id) \(UsageMath.duration(seconds))"
        }
        return VStack(alignment: .leading, spacing: 10) {
            if !values.isEmpty, values.contains(where: { $0 > 0 }) {
                UsageBars(values: values, now: data.kind == .day ? currentHour : currentDayIndex, labels: labels,
                          height: 56, labelsUnder: data.kind == .week)
            }
            Text("In " + browsers.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.leading, 44)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private func appLine(_ app: UsageApp) -> String {
        var parts = ["\(app.pickups) pickup\(app.pickups == 1 ? "" : "s")"]
        if app.notifications > 0 { parts.append("\(app.notifications) notification\(app.notifications == 1 ? "" : "s")") }
        if total > 0 { parts.append("\(Int((app.seconds / total * 100).rounded()))% of your time") }
        return parts.joined(separator: " · ")
    }
}

/// The Screen colours: cyan for screen time (beside Health's orange strain and indigo sleep), the card and line of
/// the grouped page.
enum UsageColors {
    static let cyan = [Color(red: 0.39, green: 0.82, blue: 1.0), Color(red: 0.11, green: 0.65, blue: 0.79)]
    #if os(iOS)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color(uiColor: .separator).opacity(0.6)
    #else
    static let card = Theme.row
    static let line = Color(nsColor: .separatorColor).opacity(0.6)
    #endif
    static let good = Color(red: 0.2, green: 0.75, blue: 0.4)
    static let over = Color(red: 1.0, green: 0.55, blue: 0.3)
}

/// The focus score as a ring, cyan, its number inside.
struct FocusRing: View {
    let score: Int
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(LinearGradient(colors: UsageColors.cyan, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.title2.bold().monospacedDigit())
                Text("Focus").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .frame(width: size, height: size)
    }
}

/// What the focus score is made of, opened from the ring.
private struct FocusParts: View {
    let focus: UsageMath.Focus
    let kind: UsageKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if focus.parts.isEmpty {
                Text("The average of each day's focus. Open a day to see what it's made of.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(focus.parts, id: \.name) { part in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.name).font(.subheadline.weight(.medium))
                        Text(part.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(part.score)").font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(part.score >= 67 ? UsageColors.good : part.score >= 34 ? .primary : UsageColors.over)
                }
            }
            if !focus.parts.isEmpty {
                Text("Less time than a 3-hour day and than your usual, fewer pickups and none at night score higher.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Bars of time: the hours of a day, or the days of a week or month. The bar for now is full colour, the ones to
/// come are missing; an average, if given, is a dashed line.
struct UsageBars: View {
    let values: [TimeInterval]
    var now: Int?
    let labels: [String]
    var average: TimeInterval?
    var height: CGFloat = 88
    /// One label under each bar (a week); else labels spread along the axis.
    var labelsUnder = false

    var body: some View {
        let top = max(values.max() ?? 0, average ?? 0, 60)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let gap: CGFloat = values.count > 24 ? 2 : 3
                let width = max(1, (geo.size.width - gap * CGFloat(values.count - 1)) / CGFloat(max(1, values.count)))
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(values.indices, id: \.self) { i in
                            let h = geo.size.height * CGFloat(values[i] / top)
                            UnevenRoundedRectangle(topLeadingRadius: min(3, width / 2), topTrailingRadius: min(3, width / 2))
                                .fill(LinearGradient(colors: UsageColors.cyan, startPoint: .top, endPoint: .bottom))
                                .opacity(now.map { i > $0 ? 0 : 1 } ?? 1)
                                .frame(width: width, height: values[i] > 0 ? max(2, h) : 0)
                        }
                    }
                    if let average, average > 0 {
                        Path { p in
                            let y = geo.size.height * (1 - CGFloat(average / top))
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) { Rectangle().fill(UsageColors.line).frame(height: 1) }
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: labelsUnder ? .infinity : nil)
                    if !labelsUnder && index < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(average.map { "Bars, \(UsageMath.duration($0)) on average" } ?? "Bars by hour")
    }
}

/// An app in Most used: its icon (Apple's, from the token; on the Mac, the app's own; a letter in sample data), name, time and a bar against the
/// most used one.
private struct AppRow: View {
    let app: UsageApp
    let share: Double
    /// A day's average over a week or month.
    let average: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(app: app)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(UsageMath.duration(app.seconds)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.body)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(UsageColors.cyan[0]).frame(width: max(4, geo.size.width * share))
                    }
                }
                .frame(height: 5)
                if let average {
                    Text("\(UsageMath.duration(average)) a day").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// A website in Websites: a globe, the site, its time and a bar against the most used one.
private struct SiteRow: View {
    let site: UsageSite
    let share: Double
    let average: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(hue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(site.id).lineLimit(1)
                    Spacer()
                    Text(UsageMath.duration(site.seconds)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.body)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(UsageColors.cyan[0]).frame(width: max(4, geo.size.width * share))
                    }
                }
                .frame(height: 5)
                if let average {
                    Text("\(UsageMath.duration(average)) a day").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var hue: Color {
        let h = site.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.75)
    }
}

private struct AppIcon: View {
    let app: UsageApp

    var body: some View {
        Group {
            #if os(iOS)
            if let data = app.token, let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
                Label(token).labelStyle(.iconOnly).scaleEffect(1.6)
            } else {
                letter
            }
            #else
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                letter
            }
            #endif
        }
        .frame(width: 32, height: 32)
    }

    /// Sample data, or an app that's gone: its first letter.
    private var letter: some View {
        Text(String(app.name.prefix(1)))
            .font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var hue: Color {
        let h = app.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.8)
    }
}
