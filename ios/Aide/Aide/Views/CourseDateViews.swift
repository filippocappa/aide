import SwiftUI

/// The course's exams and mid-terms on its page, what applies to the user, whether each exam is in the Exam calendar.
/// Professor and Esse3 read them; a tap changes one. Sign-ups and deadlines aren't here: the server makes them
/// reminders (docs/API.md, "Course dates").
struct CourseDatesCard: View {
    let dates: CourseDates?
    let add: () -> Void
    let read: () -> Void
    let open: (CourseDate) -> Void
    /// The course chat, where Professor proposes a missing exam for the calendar.
    let chat: () -> Void
    @State private var showPast = false
    @State private var showArchived = false

    private var all: [CourseDate] { (dates?.items ?? []).filter { CourseDatesCard.shown.contains($0.kind) } }
    private var items: [CourseDate] { all.filter { $0.archived != true } }
    /// Not being taken: kept out of the way until brought back.
    private var archived: [CourseDate] { all.filter { $0.archived == true && $0.past != true } }
    static let shown: Set<String> = ["exam", "mid-term"]
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
                if !archived.isEmpty {
                    if !upcoming.isEmpty || !past.isEmpty || items.isEmpty { RowDivider() }
                    Button { withAnimation { showArchived.toggle() } } label: {
                        HStack {
                            Label("Not taking · \(archived.count)", systemImage: "archivebox")
                            Spacer()
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showArchived ? 180 : 0))
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                    if showArchived {
                        ForEach(archived) { item in
                            RowDivider(leading: 72)
                            Button { open(item) } label: { CourseDateRow(item: item).opacity(0.55) }
                                .buttonStyle(RowPress())
                        }
                    }
                }
            }
            .card(padding: 0)
            Text("From Esse3 and the course's page and files. Tap one to change it; the next reads keep your changes. "
                 + "Sign-ups and deadlines are in Reminders.")
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
                if item.past != true, item.archived != true, let signup = item.signup { SignupLine(signup: signup) }
                if let differs = item.differs {
                    Label("The course now says \(CourseDateRow.day(differs.date, time: differs.time))",
                          systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                if item.past != true, item.archived != true, let state = item.calendar?.state, state != "in" {
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

/// An Esse3 session's sign-up on its row: open now, opening, Aide on it, or why it didn't go. Signed up and
/// "Aide signs you up" are already the row's `you` line.
private struct SignupLine: View {
    let signup: Esse3Signup

    var body: some View {
        if let busy = signup.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(busy.prefix(1).uppercased() + busy.dropFirst() + " on Esse3…")
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        } else if let error = signup.error {
            Label("Couldn't sign up: \(error)", systemImage: "exclamationmark.circle")
                .font(.caption.weight(.medium)).foregroundStyle(.orange).lineLimit(2)
                .multilineTextAlignment(.leading)
        } else if signup.state == "open", !signup.auto {
            Label(signup.closes.map { "Sign-up open until \(CourseDateRow.day($0, time: nil))" } ?? "Sign-up open",
                  systemImage: "pencil.and.list.clipboard")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.study)
        } else if signup.state == "soon", !signup.auto, let opens = signup.opens {
            Label("Sign-up opens \(CourseDateRow.day(opens, time: nil))", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
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
    /// The date as last read, after a sign-up or a cancel.
    @State private var live: CourseDate?
    @State private var asking: Ask?
    @State private var signing = false

    private enum Ask: Identifiable {
        case signUp, cancel, archive
        var id: Self { self }
    }

    static let kinds = [("exam", "Exam"), ("mid-term", "Mid-term")]

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
        _live = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let live, live.archived != true, live.past != true, let signup = live.signup { esse3(signup) }
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
                if let live, CourseDatesCard.shown.contains(live.kind), live.past != true {
                    Section {
                        if live.archived == true {
                            Button("Bring it back", systemImage: "arrow.uturn.backward") { Task { await archive(false) } }
                        } else {
                            Button("Not taking this one", systemImage: "archivebox") { asking = .archive }
                        }
                    } footer: {
                        Text(live.archived == true
                             ? "You're not taking it, so it's out of the exam plan, Professor's view and your reminders."
                             : "Out of the course page, the exam plan and your reminders, with its sign-up dates. "
                               + "It stays under Not taking until you bring it back.")
                    }
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
            .confirmationDialog(askTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { ask in
                switch ask {
                case .signUp: Button("Sign me up") { Task { await sign(cancel: false) } }
                case .cancel: Button("Cancel sign-up", role: .destructive) { Task { await sign(cancel: true) } }
                case .archive: Button("Not taking it", role: .destructive) { Task { await archive(true) } }
                }
                Button("Not now", role: .cancel) {}
            } message: { ask in
                Text(askMessage(ask))
            }
        }
    }

    // MARK: Esse3

    /// Where the sign-up stands and the one thing to do about it.
    @ViewBuilder private func esse3(_ signup: Esse3Signup) -> some View {
        let busy = signing || signup.busy != nil
        Section {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().frame(width: 28)
                } else {
                    Image(systemName: Self.symbol(signup)).font(.title3)
                        .foregroundStyle(signup.state == "booked" ? Color.green : Theme.study).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(busy ? (signup.busy ?? "signing up").prefix(1).uppercased() + (signup.busy ?? "signing up").dropFirst() + "…"
                         : Self.headline(signup))
                        .font(.body.weight(.semibold))
                    if let detail = busy ? "On Esse3, up to 20 s." : Self.detail(signup) {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if !busy, let error = signup.error {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
            }
            if signup.state == "booked" {
                if signup.canCancel {
                    Button("Cancel sign-up", role: .destructive) { asking = .cancel }.disabled(busy)
                }
            } else if signup.auto {
                Button("Don't sign me up") { Task { await sign(cancel: true) } }.disabled(busy)
            } else if signup.state == "open" || signup.state == "soon" {
                Button(signup.state == "open" ? "Sign me up" : "Sign me up when it opens",
                       systemImage: "pencil.and.list.clipboard") { asking = .signUp }
                    .font(.body.weight(.semibold)).disabled(busy)
            }
        } header: {
            Text("Esse3")
        } footer: {
            Text("Aide signs up with your UniTo login from Passwords, and only when you tap.")
        }
    }

    private static func symbol(_ s: Esse3Signup) -> String {
        if s.state == "booked" { return "checkmark.seal.fill" }
        if s.auto { return "clock.badge.checkmark" }
        return s.state == "closed" ? "lock" : "pencil.and.list.clipboard"
    }

    private static func headline(_ s: Esse3Signup) -> String {
        if s.state == "booked" { return "Signed up" }
        if s.auto { return s.opens.map { "Aide signs you up on \(CourseDateRow.day($0, time: nil))" } ?? "Aide signs you up when it opens" }
        switch s.state {
        case "open": return "Sign-up is open"
        case "soon": return s.opens.map { "Sign-up opens \(CourseDateRow.day($0, time: nil))" } ?? "Sign-up isn't open yet"
        default: return "Sign-up is closed"
        }
    }

    private static func detail(_ s: Esse3Signup) -> String? {
        let closes = s.closes.map { CourseDateRow.day($0, time: nil) }
        if s.state == "booked" {
            return s.canCancel ? closes.map { "You can cancel until \($0)." } : "It can't be cancelled any more."
        }
        if s.auto { return "As soon as it opens, then a notification." }
        if s.state == "closed" { return closes.map { "It closed on \($0)." } }
        return closes.map { "Until \($0)." }
    }

    private var askTitle: String {
        switch asking {
        case .signUp: live?.signup?.state == "open" ? "Sign up for this exam?" : "Sign up when it opens?"
        case .cancel: "Cancel your sign-up?"
        case .archive: "Not taking this exam?"
        case nil: ""
        }
    }

    private func askMessage(_ ask: Ask) -> String {
        let day = live.map { CourseDateRow.day($0.date, time: $0.time) } ?? "this day"
        let signup = live?.signup
        switch ask {
        case .signUp:
            if signup?.state == "open" { return "Aide books the \(day) exam on Esse3 with your UniTo login." }
            let opens = signup?.opens.map { CourseDateRow.day($0, time: nil) } ?? "the day it opens"
            return "Aide books the \(day) exam on Esse3 on \(opens), as soon as sign-up opens, and tells you."
        case .cancel:
            return "Aide cancels your booking for the \(day) exam on Esse3."
                + (signup?.closes.map { " You can sign up again until \(CourseDateRow.day($0, time: nil))." } ?? "")
        case .archive:
            let booked = signup?.state == "booked" ? " You're still signed up on Esse3: cancel that first if you need to." : ""
            let wanted = signup?.auto == true ? " Aide won't sign you up for it." : ""
            return "The \(day) exam leaves the course page, the exam plan and your reminders." + wanted + booked
        }
    }

    private func sign(cancel: Bool) async {
        guard let id = live?.id else { return }
        signing = true
        defer { signing = false }
        do {
            _ = cancel ? try await env.api.cancelSignUp(exam: id) : try await env.api.signUp(exam: id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if let fresh = try? await env.api.courseDates(course: course) {
            saved(fresh)
            live = fresh.items.first { $0.id == id } ?? live
        }
    }

    private func archive(_ on: Bool) async {
        guard let id = live?.id else { return }
        do {
            saved(on ? try await env.api.archiveDate(course: course, id: id) : try await env.api.unarchiveDate(course: course, id: id))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func note(_ item: CourseDate) -> String {
        if item.mine { return item.source.map { "Your edit of what \($0) says. Professor's next reads keep it." } ?? "Added by you." }
        if item.by == "esse3" { return "From Esse3, the university's records, read four times a day." }
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
