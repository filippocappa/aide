import SwiftUI

/// What the chat's events card shows (#25), apart from drawing it: the week it opens on, and each day's events.
enum EventWeek {
    /// The first day of the week `date` is in (the user's calendar decides which day that is).
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(from start: Date, calendar: Calendar = .current) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// The card's own events worth showing: the past ones are left out, unless they all are past.
    static func shown(_ events: [CalendarEvent], now: Date = .now) -> [CalendarEvent] {
        let coming = events.filter { ($0.endDate ?? .distantFuture) > now }
        return (coming.isEmpty ? events : coming).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// The week to open on: that of the first new or proposed event, else the first event shown, else this one.
    static func opening(_ events: [CalendarEvent], now: Date = .now, calendar: Calendar = .current) -> Date {
        let shown = shown(events, now: now)
        let first = shown.first(where: \.isNew) ?? shown.first
        return start(of: first?.startDate ?? now, calendar: calendar)
    }

    /// The day to select in a week: today when it's in it and has something, else the first day with something.
    static func selection(in week: Date, events: [CalendarEvent], now: Date = .now,
                          calendar: Calendar = .current) -> Date {
        let days = days(from: week, calendar: calendar)
        let busy = days.filter { !on($0, events, calendar: calendar).isEmpty }
        if let today = busy.first(where: { calendar.isDate($0, inSameDayAs: now) }) { return today }
        let firstNew = days.first { day in on(day, events, calendar: calendar).contains(where: \.isNew) }
        return firstNew ?? busy.first ?? days.first(where: { calendar.isDate($0, inSameDayAs: now) }) ?? week
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

/// The chat's events card: a week strip, and under it the chosen day. The reply's events are at full strength
/// (new and proposed ones with a bar and a chip), the rest of that day's calendar dimmed. Swipe or ‹ › for other
/// weeks; tap an event for its sheet. Proposed events go in with Add all, or one at a time from their sheet.
struct EventWeekCard: View {
    let events: [CalendarEvent]
    @EnvironmentObject private var env: AppEnvironment
    /// The card's events as the taps here left them (added, dropped, moved), until the history brings them again.
    @State private var changed: [String: CalendarEvent] = [:]
    @State private var deleted: Set<String> = []
    @State private var week: Date?
    @State private var selection: Date = .now
    /// The rest of the calendar, by the week's first day.
    @State private var others: [Date: [CalendarEvent]] = [:]
    @State private var open: CalendarEvent?
    @State private var working = false
    @State private var error: String?

    private var mine: [CalendarEvent] {
        events.filter { !deleted.contains($0.id) }.map { changed[$0.id] ?? $0 }
    }

    private var current: Date { week ?? EventWeek.opening(events) }

    var body: some View {
        let mine = EventWeek.shown(self.mine)
        let ids = Set(mine.flatMap { [$0.id, $0.event].compactMap { $0 } })
        let rest = (others[current] ?? []).filter { !ids.contains($0.id) && !deleted.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            header(mine)
            strip(mine, rest)
            day(EventWeek.on(selection, mine), EventWeek.on(selection, rest))
            let waiting = mine.filter(\.isProposed)
            if !waiting.isEmpty { addAll(waiting) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
            let dx = drag.translation.width
            guard abs(dx) > 60, abs(dx) > abs(drag.translation.height) * 1.5 else { return }
            move(weeks: dx < 0 ? 1 : -1)
        })
        .task(id: current) {
            if week == nil {
                week = current
                selection = EventWeek.selection(in: current, events: EventWeek.shown(self.mine))
            }
            await loadOthers(current)
        }
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

    private func header(_ mine: [CalendarEvent]) -> some View {
        let days = EventWeek.days(from: current)
        let proposed = mine.filter(\.isProposed).count
        let created = mine.filter { $0.change == "created" || ($0.change == "proposed" && $0.status == "added") }.count
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(range(days)).font(.subheadline.weight(.semibold))
                if proposed + created > 0 {
                    Text([proposed > 0 ? "\(proposed) proposed" : nil, created > 0 ? "\(created) new" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.toggle)
                }
            }
            Spacer(minLength: 0)
            Button { move(weeks: -1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                .accessibilityLabel("Week before")
            Button { move(weeks: 1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                .accessibilityLabel("Week after")
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
    }

    private func strip(_ mine: [CalendarEvent], _ rest: [CalendarEvent]) -> some View {
        HStack(spacing: 5) {
            ForEach(EventWeek.days(from: current), id: \.self) { day in
                let selected = Calendar.current.isDate(day, inSameDayAs: selection)
                let own = EventWeek.on(day, mine)
                Button { selection = day } label: {
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold)).opacity(0.7)
                        Text(day.formatted(.dateTime.day())).font(.callout.weight(.semibold)).monospacedDigit()
                        dots(own: own, others: EventWeek.on(day, rest).count, selected: selected)
                    }
                    .foregroundStyle(selected ? Theme.onAccent : Calendar.current.isDateInToday(day) ? Theme.toggle : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selected ? Theme.accent : Theme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                                    + (own.isEmpty ? "" : ", \(own.count) in this reply"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy, value: selection)
    }

    /// Up to three: green for a new or proposed event, solid for the reply's others, faint for the rest of the day.
    private func dots(own: [CalendarEvent], others: Int, selected: Bool) -> some View {
        let base = selected ? Theme.onAccent : Color.primary
        let marks = own.map { $0.isNew ? (selected ? Theme.onAccent : Theme.toggle) : base.opacity(0.8) }
            + Array(repeating: base.opacity(0.25), count: others)
        return HStack(spacing: 3) {
            ForEach(Array(marks.prefix(3).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 5, height: 5)
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder private func day(_ own: [CalendarEvent], _ rest: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading(selection)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if own.isEmpty && rest.isEmpty {
                Text("Nothing on this day.").font(.subheadline).foregroundStyle(.secondary)
            }
            let all = (own.map { Row(event: $0, mine: true) } + rest.map { Row(event: $0, mine: false) }).sorted { a, b in
                if a.event.allDay != b.event.allDay { return a.event.allDay }
                return (a.event.startDate ?? .distantPast) < (b.event.startDate ?? .distantPast)
            }
            ForEach(all) { row in
                Button { open = row.event } label: { EventWeekRow(event: row.event, mine: row.mine) }
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

    private func move(weeks: Int) {
        guard let next = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: current) else { return }
        withAnimation(.snappy) {
            week = next
            selection = EventWeek.selection(in: next, events: EventWeek.shown(mine) + (others[next] ?? []))
        }
    }

    private func loadOthers(_ week: Date) async {
        guard others[week] == nil else { return }
        if let found = try? await env.api.events(from: week, days: 7) { others[week] = found }
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
            others[current] = nil  // added ones are in the calendar now: they come back as the card's own
            Task { await loadOthers(current) }
        case .moved(let id, let moved):
            if var own = events.first(where: { $0.id == id }) ?? changed[id] {
                own.start = moved.start
                own.end = moved.end
                changed[id] = own
            } else {  // one of the dimmed ones
                others = others.mapValues { $0.map { $0.id == id ? moved : $0 } }
            }
            selection = moved.startDate ?? selection
            if let date = moved.startDate { week = EventWeek.start(of: date) }
        case .deleted(let id):
            deleted.insert(id)
        }
    }

    private func range(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return first.formatted(sameMonth ? .dateTime.day() : .dateTime.day().month(.abbreviated))
            + " – " + last.formatted(.dateTime.day().month(.abbreviated))
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
    /// The card's item (or a dimmed event) by its id, at its new time.
    case moved(String, CalendarEvent)
    case deleted(String)
}

/// One event under the strip: the time, the title and place; a green bar and a chip for a new or proposed one.
struct EventWeekRow: View {
    let event: CalendarEvent
    /// The reply's own: at full strength. The rest of the day is dimmed.
    let mine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.isNew ? Theme.toggle : Theme.tint(for: event.calendar ?? event.title).opacity(mine ? 1 : 0.4))
                .frame(width: 4)
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
                    if let chip { chip }
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
        .opacity(mine && !event.isDropped ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private var chip: Text? {
        let label: String
        switch (event.change, event.status) {
        case ("proposed", "added"): label = "Added"
        case ("proposed", "dropped"): label = "Removed"
        case ("proposed", _): label = "Proposed"
        case ("created", _): label = "New"
        default: return nil
        }
        let color = event.isDropped ? Color.secondary : Theme.toggle
        return Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
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
                        if let chip = status { Text(chip).font(.footnote.weight(.semibold)).foregroundStyle(Theme.toggle) }
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
