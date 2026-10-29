import SwiftUI

/// What the chat's events card shows (#25), apart from drawing it: the days of its strip, and each day's events.
enum EventWeek {
    /// The most days a strip shows (what `GET /v1/events` gives at once).
    static let maxDays = 42

    /// The card's own events worth showing: the past ones are left out, unless they all are past.
    static func shown(_ events: [CalendarEvent], now: Date = .now) -> [CalendarEvent] {
        let coming = events.filter { ($0.endDate ?? .distantFuture) > now }
        return (coming.isEmpty ? events : coming).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// The strip's days, one after the other: from today (or the first event, when that's earlier) to the last
    /// event, at least a week. `through`: a day that must be in it too (where an event was just moved).
    static func span(_ shown: [CalendarEvent], through extra: Date? = nil, now: Date = .now,
                     calendar: Calendar = .current) -> [Date] {
        let starts = shown.compactMap(\.startDate) + [now] + (extra.map { [$0] } ?? [])
        let ends = shown.compactMap { e in
            e.allDay ? e.endDate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } : e.startDate
        } + [now] + (extra.map { [$0] } ?? [])
        let first = calendar.startOfDay(for: starts.min() ?? now)
        let last = calendar.startOfDay(for: ends.max() ?? now)
        let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return (0..<min(max(count, 7), maxDays)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// The day to open on: the first with something new or proposed, else the first with any of the card's
    /// events, else today.
    static func selection(in days: [Date], events: [CalendarEvent], now: Date = .now,
                          calendar: Calendar = .current) -> Date {
        let busy = { (day: Date, test: (CalendarEvent) -> Bool) in on(day, events, calendar: calendar).contains(where: test) }
        return days.first { busy($0, \.isNew) } ?? days.first { busy($0) { _ in true } }
            ?? days.first { calendar.isDate($0, inSameDayAs: now) } ?? days.first ?? now
    }

    /// The events on a day, in time order: all-day ones (a trip of several days on each of them) first.
    static func on(_ day: Date, _ events: [CalendarEvent], calendar: Calendar = .current) -> [CalendarEvent] {
        let from = calendar.startOfDay(for: day)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from) else { return [] }
        return events.filter { e in
            guard let s = e.startDate else { return false }
            let end = max(e.endDate ?? s, s.addingTimeInterval(1))
            return s < to && end > from
        }
        .sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast)
        }
    }
}

/// The chat's events card: a strip of days to scroll, and under it the chosen day with the rest of the calendar
/// around the reply's events, each in its calendar's colour. The reply's own carry a chip (New, Proposed, Added);
/// a proposed one is drawn outlined until it's in the calendar. Tap an event for its sheet; proposed events go in
/// with Add all, or one at a time from their sheet.
struct EventWeekCard: View {
    let events: [CalendarEvent]
    @EnvironmentObject private var env: AppEnvironment
    /// The card's events as the taps here left them (added, dropped, moved), until the history brings them again.
    @State private var changed: [String: CalendarEvent] = [:]
    @State private var deleted: Set<String> = []
    /// The day tapped (or an event moved to); until then, the one `EventWeek.selection` picks.
    @State private var selection: Date?
    /// The rest of the calendar over the strip's days.
    @State private var others: [CalendarEvent] = []
    /// Bumped to fetch the rest of the calendar again (after an Add, the added ones are in it).
    @State private var reload = 0
    @State private var open: CalendarEvent?
    @State private var working = false
    @State private var error: String?

    private var mine: [CalendarEvent] {
        events.filter { !deleted.contains($0.id) }.map { changed[$0.id] ?? $0 }
    }

    var body: some View {
        let mine = EventWeek.shown(self.mine)
        let days = EventWeek.span(mine, through: selection)
        let chosen = selection ?? EventWeek.selection(in: days, events: mine)
        let ids = Set(mine.flatMap { [$0.id, $0.event].compactMap { $0 } })
        let rest = others.filter { !ids.contains($0.id) && !deleted.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            header(mine, days)
            strip(days, chosen, mine, rest)
            if mine.contains(where: \.isProposed) { legend }
            day(chosen, EventWeek.on(chosen, mine), EventWeek.on(chosen, rest))
            let waiting = mine.filter(\.isProposed)
            if !waiting.isEmpty { addAll(waiting) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: "\(days.first.map(Wire.dayString) ?? "")+\(days.count)+\(reload)") { await loadOthers(days) }
        .onChange(of: events) { changed = [:]; deleted = [] }
        .sheet(item: $open) { event in
            EventSheet(event: event, update: apply)
                .presentationDetents([.medium, .large])
        }
    }

    private struct Row: Identifiable {
        let event: CalendarEvent
        let mine: Bool
        var id: String { event.id }
    }

    // MARK: Parts

    private func header(_ mine: [CalendarEvent], _ days: [Date]) -> some View {
        let proposed = mine.filter(\.isProposed).count
        let created = mine.filter { $0.change == "created" || ($0.change == "proposed" && $0.status == "added") }.count
        let dates = mine.compactMap(\.startDate)
        return VStack(alignment: .leading, spacing: 2) {
            Text(range(dates.min() ?? days.first, dates.max() ?? days.last)).font(.subheadline.weight(.semibold))
            if proposed + created > 0 {
                Text([proposed > 0 ? "\(proposed) proposed" : nil, created > 0 ? "\(created) added" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func strip(_ days: [Date], _ chosen: Date, _ mine: [CalendarEvent], _ rest: [CalendarEvent]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        chip(day, selected: Calendar.current.isDate(day, inSameDayAs: chosen),
                             own: EventWeek.on(day, mine), rest: EventWeek.on(day, rest))
                            .id(day)
                    }
                }
            }
            .onAppear { proxy.scrollTo(chosen, anchor: .center) }
            .onChange(of: selection) { if let selection { withAnimation(.snappy) { proxy.scrollTo(selection, anchor: .center) } } }
        }
        .animation(.snappy, value: selection)
    }

    private func chip(_ day: Date, selected: Bool, own: [CalendarEvent], rest: [CalendarEvent]) -> some View {
        let today = Calendar.current.isDateInToday(day)
        return Button { selection = Calendar.current.startOfDay(for: day) } label: {
            VStack(spacing: 4) {
                Text(today ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2.weight(.semibold)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.8)
                Text(day.formatted(.dateTime.day())).font(.callout.weight(.semibold)).monospacedDigit()
                dots(own + rest)
            }
            .foregroundStyle(selected ? Theme.onAccent : .primary)
            .frame(width: 46)
            .padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if today && !selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                            + (own.isEmpty ? "" : ", \(own.count) in this reply"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Up to three, the reply's first: each in its calendar's colour, a ring for one only proposed.
    private func dots(_ events: [CalendarEvent]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                EventDot(event: event)
            }
        }
        .frame(height: 6)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label { Text("In your calendar") } icon: { Circle().fill(.secondary).frame(width: 6, height: 6) }
            Label { Text("Proposed, not added yet") } icon: {
                Circle().strokeBorder(.secondary, lineWidth: 1.2).frame(width: 6, height: 6)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func day(_ chosen: Date, _ own: [CalendarEvent], _ rest: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading(chosen)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if own.isEmpty && rest.isEmpty {
                Text("Nothing on this day.").font(.subheadline).foregroundStyle(.secondary)
            }
            let all = (own.map { Row(event: $0, mine: true) } + rest.map { Row(event: $0, mine: false) }).sorted { a, b in
                if a.event.allDay != b.event.allDay { return a.event.allDay }
                return (a.event.startDate ?? .distantPast) < (b.event.startDate ?? .distantPast)
            }
            ForEach(all) { row in
                Button { open = row.event } label: { EventWeekRow(event: row.event) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func addAll(_ waiting: [CalendarEvent]) -> some View {
        Button {
            Task { await add(waiting) }
        } label: {
            Label(waiting.count == 1 ? "Add to calendar" : "Add all (\(waiting.count))", systemImage: "calendar.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .foregroundStyle(Theme.onAccent)
        .disabled(working)
        .sensoryFeedback(.success, trigger: changed.count)
    }

    // MARK: Actions

    private func loadOthers(_ days: [Date]) async {
        guard let first = days.first else { return }
        if let found = try? await env.api.events(from: first, days: days.count) { others = found }
    }

    private func add(_ items: [CalendarEvent]) async {
        working = true
        error = nil
        do {
            for (plan, group) in Dictionary(grouping: items, by: { $0.plan ?? "" }) where !plan.isEmpty {
                apply(.items(try await env.api.addPlan(plan, items: group.map(\.id))))
            }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    private func apply(_ update: EventUpdate) {
        switch update {
        case .items(let items):
            for item in items { changed[item.id] = item }
            if let failed = items.first(where: { $0.isProposed && $0.error != nil })?.error { error = failed }
            reload += 1  // added ones are in the calendar now: they come back as the card's own
        case .moved(let id, let moved):
            if var own = events.first(where: { $0.id == id }) ?? changed[id] {
                own.start = moved.start
                own.end = moved.end
                changed[id] = own
            } else {  // one of the rest of the calendar
                others = others.map { $0.id == id ? moved : $0 }
            }
            if let date = moved.startDate { selection = Calendar.current.startOfDay(for: date) }
        case .deleted(let id):
            deleted.insert(id)
        }
    }

    private func range(_ first: Date?, _ last: Date?) -> String {
        guard let first, let last else { return "" }
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(style) }
        return first.formatted(style) + " – " + last.formatted(style)
    }

    private func heading(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()
    }
}

enum EventUpdate {
    /// A plan's items after Add or Remove.
    case items([CalendarEvent])
    /// The card's item (or one of the rest of the calendar) by its id, at its new time.
    case moved(String, CalendarEvent)
    case deleted(String)
}

/// An event's mark in its calendar's colour: filled once it's in the calendar, a ring while only proposed.
struct EventDot: View {
    let event: CalendarEvent
    var size: CGFloat = 6

    var body: some View {
        if event.isProposed {
            Circle().strokeBorder(event.tint, lineWidth: 1.2).frame(width: size, height: size)
        } else {
            Circle().fill(event.tint).frame(width: size, height: size)
        }
    }
}

/// One event under the strip: a bar in its calendar's colour (dashed while only proposed), the time, the title and
/// place, and a chip for what the reply did with it.
struct EventWeekRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            bar.frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.allDay ? "All day" : event.startDate?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if !event.allDay, let end = event.endDate {
                    Text(end.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.subheadline.weight(event.change == "found" || event.isNew ? .semibold : .regular))
                        .strikethrough(event.isDropped)
                        .multilineTextAlignment(.leading)
                    chip
                }
                let detail = [event.location, event.calendar].compactMap { $0 }.filter { !$0.isEmpty }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .opacity(event.isDropped ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var bar: some View {
        if event.isProposed {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(event.tint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        } else {
            RoundedRectangle(cornerRadius: 2).fill(event.isDropped ? Color.secondary : event.tint)
        }
    }

    @ViewBuilder private var chip: some View {
        if let label {
            let color = event.isDropped ? Color.secondary : event.tint
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
        }
    }

    private var label: String? {
        switch (event.change, event.status) {
        case ("proposed", "added"): "Added"
        case ("proposed", "dropped"): "Removed"
        case ("proposed", _): "Proposed"
        case ("created", _): "New"
        default: nil
        }
    }
}

/// An event's details, with Open in Calendar; a real one can be moved or deleted here, a proposed one added or removed.
struct EventSheet: View {
    let event: CalendarEvent
    let update: (EventUpdate) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var moving = false
    @State private var newStart: Date = .now
    @State private var confirmDelete = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.title3.weight(.semibold))
                        Text(when).foregroundStyle(.secondary)
                        if let chip = status { Text(chip).font(.footnote.weight(.semibold)).foregroundStyle(event.tint) }
                    }
                    .padding(.vertical, 4)
                    if let place = event.location, !place.isEmpty { LabeledContent("Place", value: place) }
                    if let calendar = event.calendar { LabeledContent("Calendar", value: calendar) }
                    if event.recurring {
                        Label("Repeats: change it in the Calendar app", systemImage: "repeat").font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") { Text(notes).font(.subheadline).textSelection(.enabled) }
                }
                if event.isProposed {
                    Section {
                        Button { Task { await answer(add: true) } } label: { Label("Add to calendar", systemImage: "calendar.badge.plus") }
                        Button(role: .destructive) { Task { await answer(add: false) } } label: { Label("Remove from the plan", systemImage: "xmark.circle") }
                    }
                    .disabled(working)
                } else if let id = event.calendarID {
                    Section {
                        if let start = event.startDate {
                            Button { openURL(URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)")!) } label: {
                                Label("Open in Calendar", systemImage: "calendar")
                            }
                        }
                        if !event.recurring {
                            if moving {
                                DatePicker("Starts", selection: $newStart,
                                           displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                                Button("Move here") { Task { await move(id) } }.disabled(working)
                            } else {
                                Button { newStart = event.startDate ?? .now; moving = true } label: {
                                    Label("Move", systemImage: "arrow.right.circle")
                                }
                            }
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                                .disabled(working)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete \(event.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It goes from your calendar on every device.")
            }
        }
    }

    private var when: String {
        guard let start = event.startDate else { return "" }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if event.allDay {
            guard let end = event.endDate.flatMap({ Calendar.current.date(byAdding: .day, value: -1, to: $0) }),
                  !Calendar.current.isDate(end, inSameDayAs: start) else { return "\(day), all day" }
            return "\(day) – \(end.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
        }
        return "\(day), \(event.timeText)"
    }

    private var status: String? {
        switch (event.change, event.status) {
        case ("proposed", "added"): "Added from the plan"
        case ("proposed", "dropped"): "Removed from the plan"
        case ("proposed", _): "Proposed: not in your calendar yet"
        case ("created", _): "Just added"
        default: nil
        }
    }

    private func answer(add: Bool) async {
        guard let plan = event.plan else { return }
        working = true
        error = nil
        do {
            let items = add ? try await env.api.addPlan(plan, items: [event.id])
                            : try await env.api.dropPlan(plan, items: [event.id])
            update(.items(items))
            if let failed = items.first(where: { $0.id == event.id })?.error, add { error = failed } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    private func move(_ id: String) async {
        guard let start = event.startDate, let end = event.endDate else { return }
        working = true
        error = nil
        do {
            let length = end.timeIntervalSince(start)
            let moved: CalendarEvent
            if event.allDay {
                let days = max(0, (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1) - 1)
                let last = Calendar.current.date(byAdding: .day, value: days, to: newStart) ?? newStart
                moved = try await env.api.moveEvent(id, start: Wire.dayString(newStart), end: Wire.dayString(last))
            } else {
                moved = try await env.api.moveEvent(id, start: Wire.utc(newStart),
                                                    end: Wire.utc(newStart.addingTimeInterval(length)))
            }
            update(.moved(event.id, moved))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    private func delete() async {
        guard let id = event.calendarID else { return }
        working = true
        do {
            try await env.api.deleteEvent(id)
            update(.deleted(event.id))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
