import SwiftUI

/// The course's dates on its page: exams, mid-terms and deadlines, what applies to the user, whether each exam is in
/// the Exam calendar. Professor reads them from the course's page and files; a tap changes one.
struct CourseDatesCard: View {
    let dates: CourseDates?
    let add: () -> Void
    let read: () -> Void
    let open: (CourseDate) -> Void
    /// The course chat, where Professor proposes a missing exam for the calendar.
    let chat: () -> Void
    @State private var showPast = false

    private var items: [CourseDate] { dates?.items ?? [] }
    private var upcoming: [CourseDate] { items.filter { $0.past != true } }
    private var past: [CourseDate] { items.filter { $0.past == true } }
    private var reading: Bool { dates?.reading == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Dates").font(.title3.weight(.bold))
                Spacer()
                if reading {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…") }
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Button("Read again", systemImage: "arrow.clockwise", action: read)
                        .labelStyle(.iconOnly).font(.body.weight(.semibold)).foregroundStyle(Theme.study)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                Button("Add a date", systemImage: "plus", action: add)
                    .labelStyle(.iconOnly).font(.body.weight(.semibold)).foregroundStyle(Theme.study)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                if upcoming.isEmpty {
                    Text(items.isEmpty ? "No dates yet. Professor reads them from the course's page and files, and "
                         + "again when one that looks like an exam notice comes."
                         : "Nothing coming up.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider(leading: 72) }
                    Button { open(item) } label: { CourseDateRow(item: item, chat: chat) }
                        .buttonStyle(RowPress())
                }
                if !past.isEmpty {
                    if !upcoming.isEmpty || items.isEmpty { RowDivider() }
                    Button { withAnimation { showPast.toggle() } } label: {
                        HStack {
                            Text(past.count == 1 ? "1 past" : "\(past.count) past")
                            Spacer()
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showPast ? 180 : 0))
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                    if showPast {
                        ForEach(past) { item in
                            RowDivider(leading: 72)
                            Button { open(item) } label: { CourseDateRow(item: item, chat: chat).opacity(0.55) }
                                .buttonStyle(RowPress())
                        }
                    }
                }
            }
            .card(padding: 0)
            Text("From the course's page and files. Tap one to change it; Professor's next reads keep your changes.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
}

/// A date: the day in a block, what it is, when and where, the user's own line, where it was read.
struct CourseDateRow: View {
    let item: CourseDate
    var chat: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DateBlock(day: item.day, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.what.prefix(1).uppercased() + item.what.dropFirst())
                        .font(.body.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if let away { Text(away).font(.caption.weight(.medium)).foregroundStyle(soon ? Color.orange : .secondary) }
                }
                Text(whenWhere).font(.subheadline).foregroundStyle(.secondary)
                if let you = item.you {
                    Label(you, systemImage: "person.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.study)
                        .multilineTextAlignment(.leading)
                }
                if let differs = item.differs {
                    Label("The course now says \(CourseDateRow.day(differs.date, time: differs.time))",
                          systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                if item.past != true, let state = item.calendar?.state, state != "in" {
                    Button(action: chat) {
                        Label(state == "moved" ? "Moved? Your calendar has \(CourseDateRow.day(item.calendar?.on ?? "", time: nil))"
                              : "Not in your calendar",
                              systemImage: state == "moved" ? "calendar.badge.exclamationmark" : "calendar.badge.plus")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                if let note = footnote {
                    Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var tint: Color { item.kind == "deadline" || item.kind == "other" ? .secondary : Theme.study }

    private var days: Int? { item.day.map { StudyDay.days(to: $0) } }
    private var soon: Bool { (days ?? 99) < 7 && (item.kind == "exam" || item.kind == "mid-term") }

    /// "Today", "Tomorrow", "in 4 days"; nil when past or months away.
    private var away: String? {
        guard item.past != true, let days else { return nil }
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2..<60: return "in \(days) days"
        default: return nil
        }
    }

    /// "Wed · 11:00–13:00 · Aula 5", "Mon · All day".
    private var whenWhere: String {
        var parts = [item.day?.formatted(.dateTime.weekday(.abbreviated)) ?? item.date]
        if let time = item.time { parts.append(item.end.map { "\(time)–\($0)" } ?? time) } else { parts.append("All day") }
        if let room = item.room { parts.append(room) }
        return parts.joined(separator: " · ")
    }

    private var footnote: String? {
        if item.mine { return item.source.map { "Your edit · was \($0)" } ?? "Added by you" }
        return item.source.map { "From \($0)" }
    }

    /// "Wed 14 Jan, 11:00".
    static func day(_ date: String, time: String?) -> String {
        let day = Wire.day(date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? date
        return time.map { "\(day), \($0)" } ?? day
    }
}

/// "NOV" over "4", like a calendar's page.
private struct DateBlock: View {
    let day: Date?
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(day?.formatted(.dateTime.month(.abbreviated)).uppercased() ?? "—")
                .font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(day?.formatted(.dateTime.day()) ?? "")
                .font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(.primary)
        }
        .frame(width: 42, height: 48)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Adding a date, or changing one Professor read (kept through its later reads).
struct CourseDateEditor: View {
    let course: Int
    /// nil: a new one.
    let item: CourseDate?
    let saved: (CourseDates) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CourseDateBody
    @State private var day: Date
    @State private var timed: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var error: String?
    @State private var working = false
    @State private var confirmDelete = false

    static let kinds = [("exam", "Exam"), ("mid-term", "Mid-term"), ("deadline", "Deadline"), ("other", "Other")]

    init(course: Int, item: CourseDate?, saved: @escaping (CourseDates) -> Void) {
        self.course = course
        self.item = item
        self.saved = saved
        let body = item.map(CourseDateEditor.body) ?? CourseDateBody(what: "", kind: "exam", date: Wire.dayString(.now))
        _draft = State(initialValue: body)
        _day = State(initialValue: Wire.day(body.date) ?? .now)
        _timed = State(initialValue: body.time != nil)
        let first = Self.clock(body.time) ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
        _start = State(initialValue: first)
        _end = State(initialValue: Self.clock(body.end) ?? first.addingTimeInterval(2 * 3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let differs = item?.differs {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CourseDateRow.day(differs.date, time: differs.time)).font(.body.weight(.medium))
                                if let source = differs.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Use it") { use(differs) }.buttonStyle(.borderedProminent).tint(Theme.study)
                        }
                    } header: {
                        Text("The course now says")
                    }
                }
                Section {
                    TextField("What it is", text: $draft.what)
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                    Toggle("At a time", isOn: $timed.animation())
                    if timed {
                        DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                        DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
                Section {
                    TextField("Room", text: text(\.room))
                } footer: {
                    Text("Where you sit it, when the rooms are split.")
                }
                Section {
                    TextField("Your group, room or turn", text: text(\.you), axis: .vertical)
                } header: {
                    Label("For you", systemImage: "person.fill")
                } footer: {
                    Text("Professor finds it by your name on Moodle in lists of groups, rooms and sign-ups.")
                }
                Section {
                    TextField("What it covers, how to sign up", text: text(\.details), axis: .vertical)
                } header: {
                    Text("Details")
                } footer: {
                    if let item { Text(note(item)) }
                }
                if item != nil {
                    Section {
                        Button(item?.mine == true && item?.source == nil ? "Delete the date" : "Hide the date",
                               role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(item == nil ? "New date" : "Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Save") { Task { await save() } }
                            .disabled(draft.what.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .confirmationDialog("Hide this date?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(item?.source == nil ? "Delete" : "Hide", role: .destructive) { Task { await delete() } }
            } message: {
                Text(item?.source == nil ? "It's gone from the course's dates."
                     : "Professor won't add it back when it reads the course again.")
            }
        }
    }

    private func note(_ item: CourseDate) -> String {
        if item.mine { return item.source.map { "Your edit of what \($0) says. Professor's next reads keep it." } ?? "Added by you." }
        return item.source.map { "Read by Professor from \($0)." } ?? "Read by Professor."
    }

    /// An optional field as a text field: empty is nil.
    private func text(_ key: WritableKeyPath<CourseDateBody, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" },
                set: { draft[keyPath: key] = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
    }

    private var current: CourseDateBody {
        var body = draft
        body.what = body.what.trimmingCharacters(in: .whitespacesAndNewlines)
        body.date = Wire.dayString(day)
        body.time = timed ? Self.clock(start) : nil
        body.end = timed && end > start ? Self.clock(end) : nil
        return body
    }

    private func use(_ differs: CourseDate.Differs) {
        day = Wire.day(differs.date) ?? day
        timed = differs.time != nil
        if let time = Self.clock(differs.time) { start = time; end = time.addingTimeInterval(2 * 3600) }
        Task { await save() }
    }

    private func save() async {
        let body = current
        if let item, body == Self.body(item) { dismiss(); return }
        working = true
        defer { working = false }
        do {
            if let item {
                saved(try await env.api.updateCourseDate(course: course, id: item.id, body))
            } else {
                saved(try await env.api.addCourseDate(course: course, body))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let item else { return }
        do {
            saved(try await env.api.deleteCourseDate(course: course, id: item.id))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func body(_ item: CourseDate) -> CourseDateBody {
        CourseDateBody(what: item.what, kind: item.kind, date: item.date, time: item.time, end: item.time == nil ? nil : item.end,
                       room: item.room, you: item.you, details: item.details?.isEmpty == true ? nil : item.details)
    }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "11:00" as today at 11:00, and back.
    private static func clock(_ s: String?) -> Date? {
        guard let s, let t = clockFormat.date(from: s) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: t)
        return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: .now)
    }

    private static func clock(_ d: Date) -> String { clockFormat.string(from: d) }
}
