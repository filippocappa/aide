import SwiftUI

/// What the Pebble in the menu bar opens: a small panel, not a plain menu. Pebble breathing at the top with the time
/// of day, a box to ask Aide, the day at a glance (the sidebar's rings and bars), what's next today, what's waiting,
/// the team to open a chat with, and the sections as icons. Loaded again each time it opens.
struct MacMenuBarPanel: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var glance = MacGlance.shared
    /// Kept between openings, so the panel opens filled and its size doesn't jump.
    @ObservedObject private var model = MacPanelModel.shared
    @Environment(\.openWindow) private var openWindow

    private var today: TodayResponse? { model.today }
    private var waiting: Int { model.waiting }
    @State private var question = ""
    @FocusState private var asking: Bool

    private var aide: Agent { chat.orchestrator }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 14) {
                header(context.date)
                if settings.isConfigured {
                    askBox
                    MacGlanceCard(glance: glance, open: go)
                    upNext(context.date)
                    if waiting > 0 { waitingRow }
                    team
                } else {
                    Button { go(.settings) } label: {
                        Label("Set up the server in Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PanelRowStyle())
                }
                Divider().opacity(0.6)
                footer
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(alignment: .top) {
            // Aide's glow at the top, as on its pages, so the panel isn't a flat grey sheet.
            LinearGradient(colors: [aide.tint.opacity(0.28), aide.tint.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)
        }
        .task { await load() }
    }

    // MARK: The pieces

    private func header(_ now: Date) -> some View {
        HStack(spacing: 12) {
            LivePebble(mood: mood(now), size: 42, figure: aide.figure)
                .foregroundStyle(aide.tint)
                .shadow(color: aide.tint.opacity(0.45), radius: 8)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.greeting(now))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { show() } label: { Image(systemName: "macwindow") }
                .buttonStyle(PanelIconStyle())
                .help("Open Aide")
            Button { go(.settings) } label: { Image(systemName: "gearshape") }
                .buttonStyle(PanelIconStyle())
                .help("Settings")
        }
    }

    private var askBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(aide.tint)
            TextField("Ask Aide anything…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($asking)
                .onSubmit(ask)
            if !question.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(aide.tint)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(asking ? aide.tint.opacity(0.6) : .primary.opacity(0.08), lineWidth: 1)
        }
        .animation(.spring(duration: 0.25), value: question.isEmpty)
    }

    private func upNext(_ now: Date) -> some View {
        MiniCalendar(now: now, model: model, tint: aide.tint, open: { go(.today) })
    }

    private var waitingRow: some View {
        Button { go(.activity) } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .primary.opacity(0.7))
                    .frame(width: 18)
                Text(waiting == 1 ? "1 thing waiting for you" : "\(waiting) things waiting for you")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(PanelRowStyle(fill: .orange.opacity(0.12)))
    }

    private var team: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading("Your team")
            HStack(spacing: 4) {
                ForEach(chat.agents) { agent in
                    Button { talk(to: agent) } label: {
                        VStack(spacing: 4) {
                            LivePebble(mood: "awake", size: 30, figure: agent.figure)
                                .foregroundStyle(agent.tint)
                                .allowsHitTesting(false)
                            Text(agent.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelRowStyle(padding: 6))
                    .help("Chat with \(agent.name)")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            ForEach(MacSection.allCases.filter { $0 != .settings && $0 != .team }) { section in
                Button { go(section) } label: { Image(systemName: section.icon) }
                    .buttonStyle(PanelIconStyle())
                    .help(section.title)
            }
            Spacer(minLength: 0)
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(PanelIconStyle())
                .help("Quit Aide")
        }
    }

    // MARK: Doing things

    private func load() async {
        guard settings.isConfigured else { return }
        async let g: Void = glance.load(env)
        async let t = try? env.api.today()
        async let a = try? env.api.approvals()
        let (day, approvals) = await (t, a)
        _ = await g
        // No animation: the panel's window resizes to the new rows, and an animated change left them overlapping.
        if let day { model.today = day }
        if let approvals { model.waiting = approvals.waiting }
    }

    /// Opens the window on a section; the panel closes as the window takes over.
    private func go(_ section: MacSection) {
        show()
        MacNavigation.shared.section = section
    }

    private func talk(to agent: Agent) {
        show()
        env.push.route = .agent(agent.id)
    }

    /// The question in a new chat with Aide, in the window.
    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        go(.team)
        Task {
            await chat.newChat(with: chat.orchestrator)
            await chat.send(text)
        }
    }

    private func show() {
        openWindow(id: MacWindow.main)
        NSApplication.shared.activate()
    }

    private func mood(_ now: Date) -> String {
        if chat.isSending { return "thinking" }
        let hour = Calendar.current.component(.hour, from: now)
        return hour < 6 || hour >= 23 ? "sleeping" : "awake"
    }

    static func greeting(_ now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
    }
}

/// What the panel last loaded.
@MainActor
final class MacPanelModel: ObservableObject {
    static let shared = MacPanelModel()
    @Published var today: TodayResponse?
    @Published var waiting = 0
    /// The calendar's events by the first day of the week they were loaded for.
    @Published var grids: [Date: [CalendarEvent]] = [:]

    func loadGrid(from first: Date, _ env: AppEnvironment) async {
        guard let events = try? await env.api.events(from: first, days: 7) else { return }
        grids[first] = events
    }
}

// MARK: - The little calendar

/// A week, Monday first (the locale's first weekday): today filled, the chosen day ringed, a dot per calendar with
/// something on that day. Under it the chosen day's events, and on today its reminders.
private struct MiniCalendar: View {
    let now: Date
    @ObservedObject var model: MacPanelModel
    let tint: Color
    var open: () -> Void

    @EnvironmentObject private var env: AppEnvironment
    @State private var week = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    @State private var chosen = Calendar.current.startOfDay(for: .now)

    private var cal: Calendar { .current }

    /// The week's first day (the locale's first weekday: Monday here).
    private var first: Date { week }

    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week) } }

    /// "This week", "Next week", "Last week", else "3–9 Nov".
    private var title: String {
        let weeks = cal.dateComponents([.weekOfYear], from: cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now,
                                       to: week).weekOfYear ?? 0
        switch weeks {
        case 0: return "This week"
        case 1: return "Next week"
        case -1: return "Last week"
        default:
            let last = days.last ?? week
            let sameMonth = cal.isDate(week, equalTo: last, toGranularity: .month)
            return "\(week.formatted(sameMonth ? .dateTime.day() : .dateTime.day().month(.abbreviated)))–"
                + last.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var byDay: [Date: [CalendarEvent]] {
        var out: [Date: [CalendarEvent]] = [:]
        for event in model.grids[first] ?? [] {
            guard let start = event.startDate else { continue }
            var day = cal.startOfDay(for: start)
            let end = event.endDate ?? start
            repeat {
                out[day, default: []].append(event)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < end && out.count < 400
        }
        return out.mapValues { $0.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) } }
    }

    var body: some View {
        let byDay = byDay
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                if !cal.isDateInToday(chosen) {
                    Button("Today") { jump(to: now) }
                        .buttonStyle(PanelRowStyle(padding: 4))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint)
                }
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(PanelIconStyle())
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(PanelIconStyle())
            }

            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                    ForEach(days, id: \.self) { day in
                        DayCell(day: day,
                                inMonth: true,
                                today: cal.isDate(day, inSameDayAs: now),
                                chosen: cal.isDate(day, inSameDayAs: chosen),
                                dots: dots(byDay[day] ?? []),
                                tint: tint)
                            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { chosen = day } }
                    }
                }
            }
            .padding(6)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            agenda(byDay[chosen] ?? [])
        }
        .task(id: first) { await model.loadGrid(from: first, env) }
    }

    @ViewBuilder private func agenda(_ events: [CalendarEvent]) -> some View {
        let isToday = cal.isDate(chosen, inSameDayAs: now)
        let reminders = isToday ? (model.today?.reminders ?? []).filter { !$0.completed && !$0.deleted }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) } : []
        let shown = isToday ? events.filter { $0.allDay || ($0.endDate ?? .distantPast) > now } : events
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading(isToday ? "Up next" : cal.isDateInTomorrow(chosen) ? "Tomorrow"
                         : chosen.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if model.grids[first] == nil && model.today == nil {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 8)
            } else if shown.isEmpty && reminders.isEmpty {
                Label(isToday ? "Nothing else on today" : "Nothing on", systemImage: "moon.stars")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ForEach(shown.prefix(4)) { event in
                Button(action: open) { EventLine(event: event, now: now) }
                    .buttonStyle(PanelRowStyle(padding: 6))
            }
            if shown.count > 4 {
                Button(action: open) {
                    Text("\(shown.count - 4) more").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PanelRowStyle(padding: 6))
            }
            ForEach(reminders.prefix(3)) { reminder in
                Button(action: open) { ReminderLine(reminder: reminder, now: now) }
                    .buttonStyle(PanelRowStyle(padding: 6))
            }
        }
    }

    /// Up to three dots, one per calendar.
    private func dots(_ events: [CalendarEvent]) -> [Color] {
        var seen = Set<String>(), out: [Color] = []
        for event in events where out.count < 3 {
            if seen.insert(event.calendar ?? event.title).inserted { out.append(event.tint) }
        }
        return out
    }

    private var weekdays: [String] {
        let names = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { names[(cal.firstWeekday - 1 + $0) % 7] }
    }

    private func shift(_ weeks: Int) {
        guard let next = cal.date(byAdding: .weekOfYear, value: weeks, to: week) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            week = next
            chosen = cal.isDate(next, equalTo: now, toGranularity: .weekOfYear) ? cal.startOfDay(for: now) : next
        }
    }

    private func jump(to day: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            week = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            chosen = cal.startOfDay(for: day)
        }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let today: Bool
    let chosen: Bool
    let dots: [Color]
    let tint: Color
    @State private var hover = false

    var body: some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 12, weight: today ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(today ? AnyShapeStyle(Color.black.opacity(0.85))
                                 : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .background {
                    if today {
                        Circle().fill(tint.gradient).shadow(color: tint.opacity(0.5), radius: 4)
                    } else if chosen {
                        Circle().strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                    } else if hover {
                        Circle().fill(.primary.opacity(0.08))
                    }
                }
            HStack(spacing: 2) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                    Circle().fill(color).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
            .opacity(inMonth ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Lines

private struct EventLine: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        let start = event.startDate ?? now
        let end = event.endDate ?? now
        let on = start <= now && end > now
        HStack(spacing: 10) {
            Capsule().fill(event.tint.gradient).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(when(start, end, on) + (event.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !event.allDay, start > now, start.timeIntervalSince(now) < 3600 {
                Text("in \(max(1, Int(start.timeIntervalSince(now) / 60))) min")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(event.tint.opacity(0.2), in: Capsule())
                    .foregroundStyle(event.tint)
            } else if on && !event.allDay {
                Circle().fill(event.tint).frame(width: 7, height: 7)
                    .shadow(color: event.tint, radius: 4)
            }
        }
    }

    private func when(_ start: Date, _ end: Date, _ on: Bool) -> String {
        if event.allDay { return "All day" }
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return on ? "Now · until \(time(end))" : "\(time(start))–\(time(end))"
    }
}

private struct ReminderLine: View {
    let reminder: Reminder
    let now: Date

    var body: some View {
        let due = reminder.dueDate
        let late = reminder.overdue || (due.map { $0 < now } ?? false)
        HStack(spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(late ? .red : .secondary)
                .frame(width: 14)
            Text(reminder.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if let due {
                Text(due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(late ? .red : .secondary)
            }
        }
    }
}

private struct PanelHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }
}

// MARK: - Styles

/// A row that lights up under the pointer, as menu items do.
private struct PanelRowStyle: ButtonStyle {
    var fill: Color? = nil
    var padding: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hover in
            configuration.label
                .padding(padding)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(fill ?? .clear)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.08 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A round icon button for the header and the footer.
private struct PanelIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hover in
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0), in: Circle())
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

private struct Hovering<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false
    var body: some View { content(hover).onHover { hover = $0 } }
}
