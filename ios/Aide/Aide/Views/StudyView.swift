import SwiftUI
import UniformTypeIdentifiers

extension Theme {
    /// Professor's colour: the Study tab's one hue.
    static let study = Theme.readable(0x7A4FD0)
}

/// The Study tab: what's up next, what to review, and the courses, each with its notebook, lectures and files
/// (docs/API.md, "Study", "Notebook", "Quizzes and review sessions").
struct StudyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @State private var overview: StudyOverview?
    @State private var reviews: [ReviewSession] = []
    @State private var error: String?
    @State private var path: [StudyCourse] = []
    @State private var practice: StudyCourse?
    @State private var result: String?

    private var courses: [StudyCourse] { overview?.courses ?? [] }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TopBlock("Study", overline: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                        if overview != nil { Text(line).foregroundStyle(.secondary) }
                    }
                    if let error { ErrorCard(text: error) }
                    if let now = overview?.now {
                        Label("\(now.name.prefix(1).uppercased() + now.name.dropFirst()) is on now",
                              systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.toggle).card()
                    }
                    if !reviews.isEmpty {
                        UpNextCard(sessions: Array(reviews.prefix(3)), name: name) { session in
                            Task { await quiz(session.course) }
                        } open: { session in
                            if let course = courses.first(where: { $0.id == session.course }) { path = [course] }
                        }
                    }
                    if let due = toReview {
                        ToReviewCard(course: due.course, count: due.count, topic: due.topic) { practice = due.course }
                    }
                    if overview == nil, error == nil {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.row).frame(height: 116)
                        }
                    } else if !courses.isEmpty {
                        Text("Courses").font(.title3.weight(.bold)).padding(.horizontal, 4).padding(.top, 8)
                        ForEach(courses) { course in
                            NavigationLink(value: course) {
                                CourseCard(course: course, next: reviews.first { $0.course == course.id })
                            }
                            .buttonStyle(CardPress())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .previewAnchor()
            .pageGlow(Theme.study)
            .navigationDestination(for: StudyCourse.self) { CourseView(course: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Moodle", systemImage: "building.columns") { env.showMoodle = true }
                }
            }
            .fullScreenCover(item: $practice, onDismiss: { Task { await load() } }) { course in
                PracticeExamView(course: course.id, courseName: course.name)
            }
            .sheet(item: Binding(get: { result.map(QuizID.init) }, set: { result = $0?.id })) { QuizResultSheet(id: $0.id) }
            .task {
                await load()
                openPreview()
            }
            .refreshable { await load() }
        }
    }

    private struct QuizID: Identifiable { let id: String }

    /// The page's one line: the next review sessions and the next exam.
    private var line: String {
        var parts: [String] = []
        if let start = reviews.first.flatMap({ Wire.parse($0.start) }) {
            let same = reviews.filter { Wire.parse($0.start).map { Calendar.current.isDate($0, inSameDayAs: start) } ?? false }.count
            parts.append("\(same == 1 ? "A review session" : "\(same) review sessions") \(StudyDay.phrase(start)).")
        }
        let exams = courses.compactMap { c in c.nextExam.flatMap { e in Wire.parse(e.date).map { (e.title, $0) } } }
        if let (title, date) = exams.min(by: { $0.1 < $1.1 }), StudyDay.days(to: date) < 14 {
            parts.append("\(title.prefix(1).uppercased() + title.dropFirst()) \(StudyDay.phrase(date)).")
        }
        if parts.isEmpty {
            parts.append(courses.isEmpty ? "Courses come from the timetable calendar." : "Nothing planned. Practise whenever you like.")
        }
        return parts.joined(separator: " ")
    }

    /// The course with the most questions last answered wrong or blank, and its most missed topic.
    private var toReview: (course: StudyCourse, count: Int, topic: TopicMastery?)? {
        courses.compactMap { course -> (StudyCourse, Int, TopicMastery?)? in
            let mastery = course.notebook?.mastery ?? []
            let count = mastery.reduce(0) { $0 + $1.learning }
            return count > 0 ? (course, count, mastery.max { $0.learning < $1.learning }) : nil
        }
        .max { $0.1 < $1.1 }
    }

    private func name(_ course: Int) -> String {
        courses.first { $0.id == course }?.title ?? reviews.first { $0.course == course }?.name ?? "Course"
    }

    private func load() async {
        do {
            overview = try await env.api.study()
            reviews = (try? await env.api.reviewSessions()) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The course's chat, with Professor quizzing out loud.
    private func quiz(_ id: Int) async {
        guard let course = courses.first(where: { $0.id == id }) else { return }
        do {
            push.route = .quiz(try await CourseView.chat(for: course, api: env.api))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Simulator screenshots: `-previewOpen course:5` opens that course, `practice:5` its practice exam (with
    /// `-previewExam start`, already started), `result:x_…` a finished one.
    private func openPreview() {
        #if DEBUG
        guard env.settings.isPreview, let target = UserDefaults.standard.string(forKey: "previewOpen") else { return }
        let parts = target.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "result" { result = parts[1]; return }
        guard let course = courses.first(where: { String($0.id) == parts[1] }) else { return }
        if parts[0] == "course" { path = [course] }
        if parts[0] == "practice" { practice = course }
        #endif
    }
}

/// Days as the Study pages say them.
enum StudyDay {
    private static var calendar: Calendar { .current }

    static func days(to date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "Today", "Tomorrow", "Monday" within the week, else "Tue 10 Nov".
    static func word(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let days = days(to: date)
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func relative(_ date: Date) -> Bool { calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) }

    /// "today", "tomorrow", "on Monday".
    static func phrase(_ date: Date) -> String { relative(date) ? word(date).lowercased() : "on \(word(date))" }

    /// "Tomorrow, 09:00"; lowercased within a sentence.
    static func when(_ date: Date, inSentence: Bool = false) -> String {
        let day = inSentence && relative(date) ? word(date).lowercased() : word(date)
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }
}

struct ErrorCard: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red).card()
    }
}

/// The next review sessions as a timeline; the first one a tap from its quiz or its course.
private struct UpNextCard: View {
    let sessions: [ReviewSession]
    let name: (Int) -> String
    let quiz: (ReviewSession) -> Void
    let open: (ReviewSession) -> Void

    private var first: Date? { sessions.first.flatMap { Wire.parse($0.start) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Up next · \(first.map(StudyDay.word) ?? "")".uppercased())
                .font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    row(session, index: index)
                }
            }
            if let session = sessions.first {
                HStack(spacing: 10) {
                    Button { quiz(session) } label: {
                        Label("Quiz me", systemImage: "waveform")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(.white).background(Theme.study, in: Capsule())
                    }
                    Button { open(session) } label: {
                        Text("Open course")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(.primary).background(Theme.chip, in: Capsule())
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(CardPress())
            }
        }
        .card()
    }

    private func row(_ session: ReviewSession, index: Int) -> some View {
        let start = Wire.parse(session.start)
        let otherDay = start.map { s in first.map { !Calendar.current.isDate(s, inSameDayAs: $0) } ?? false } ?? false
        let last = index == sessions.count - 1
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(start?.formatted(date: .omitted, time: .shortened) ?? "").font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if otherDay, let start {
                    Text(start.formatted(.dateTime.weekday(.abbreviated))).font(.caption2)
                }
            }
            .foregroundStyle(index == 0 ? Theme.study : .secondary)
            .frame(width: 50, alignment: .trailing)
            VStack(spacing: 0) {
                Circle().fill(index == 0 ? Theme.study : Theme.line).frame(width: 10, height: 10).padding(.top, 5)
                if !last { Rectangle().fill(Theme.line).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Review: \(name(session.course))").font(.body.weight(index == 0 ? .semibold : .regular))
                Text(([ "\(session.minutes) min"] + session.topics).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.bottom, last ? 0 : 16)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What was last answered wrong or blank, in the course with the most of it.
private struct ToReviewCard: View {
    let course: StudyCourse
    let count: Int
    let topic: TopicMastery?
    let review: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.counterclockwise")
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.study)
                .frame(width: 44, height: 44).background(Theme.study.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) to review").font(.headline)
                Text([topic.map { "Most missed: \($0.title)" }, course.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Chip(title: "Review now", style: .prominent, tint: Theme.study, action: review)
        }
        .card()
    }
}

/// A course on the Study tab: its exam, a dot per topic for how well it's known, and its next review.
private struct CourseCard: View {
    let course: StudyCourse
    let next: ReviewSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(course.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let exam = course.nextExam, let date = Wire.parse(exam.date) { ExamTag(date: date) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let mastery = course.notebook?.mastery, !mastery.isEmpty { MasteryDots(topics: mastery) }
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            if let start = next.flatMap({ Wire.parse($0.start) }) {
                Label("Next review \(StudyDay.when(start, inSentence: true))", systemImage: "calendar")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var detail: String {
        var parts: [String] = []
        if let nb = course.notebook {
            let mastery = nb.mastery ?? []
            let known = mastery.reduce(0) { $0 + $1.known }, learning = mastery.reduce(0) { $0 + $1.learning }
            let unseen = mastery.reduce(0) { $0 + $1.unseen }
            if nb.writing == true {
                parts.append("Notes being written")
            } else if nb.topics == 0 && (nb.proposals ?? 0) == 0 {
                parts.append("Topics being drafted") // started, with nothing to show or answer yet
            } else {
                parts.append(nb.topics == 1 ? "1 topic" : "\(nb.topics) topics")
                if known + learning > 0 {
                    parts += ["\(known) known", "\(learning) learning", "\(unseen) not tried"]
                } else if let q = nb.questions, q > 0 {
                    parts.append("\(q) questions, none tried yet")
                }
            }
            if let p = nb.proposals, p > 0 { parts.append(p == 1 ? "1 to answer" : "\(p) to answer") }
        } else {
            if let n = course.lectures, n > 0 { parts.append(n == 1 ? "1 lecture" : "\(n) lectures") }
            if let n = course.files, n > 0 { parts.append(n == 1 ? "1 file" : "\(n) files") }
            parts.append("no notebook yet")
        }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// The exam's day as a small capsule: orange within the week.
struct ExamTag: View {
    let date: Date
    /// "Macroeconomics exam": the whole line, on the course's page.
    var title: String?

    var body: some View {
        let soon = StudyDay.days(to: date) < 7
        Label(title.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) · \(StudyDay.when(date))" }
                ?? "Exam \(StudyDay.phrase(date).replacingOccurrences(of: "on ", with: ""))",
              systemImage: "calendar")
            .font(.caption.weight(.semibold))
            .foregroundStyle(soon ? Color.orange : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(soon ? Color.orange.opacity(0.15) : Theme.chip, in: Capsule())
            .fixedSize()
    }
}

extension TopicMastery.Level {
    var color: Color {
        switch self {
        case .known: Theme.study
        case .learning: Theme.study.opacity(0.42)
        case .unseen: Color.primary.opacity(0.12)
        }
    }
}

/// A dot per topic: known, being learnt, not tried.
struct MasteryDots: View {
    let topics: [TopicMastery]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 12, maximum: 12), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(topics) { Circle().fill($0.level.color).frame(width: 12, height: 12) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        let known = topics.filter { $0.level == .known }.count, learning = topics.filter { $0.level == .learning }.count
        return "\(known) topics known, \(learning) being learnt, \(topics.count - known - learning) not tried"
    }
}

/// A course: what's waiting for an answer, practice, how well each topic is known, review sessions, lectures and files.
struct CourseView: View {
    let course: StudyCourse
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @State private var notebook: NotebookStatus?
    @State private var bank: QuizBank?
    @State private var writer: NotesWriter?
    /// What was just set going, with its symbol: figures being looked for, exercises being written.
    @State private var note: (text: String, symbol: String)?
    @State private var lectures: [Lecture] = []
    @State private var files: [StudyFile] = []
    @State private var reviews: [ReviewSession] = []
    @State private var error: String?
    @State private var busy: String?
    @State private var showPractice = false
    @State private var confirmStart = false
    @State private var importing: Import?
    @State private var openFile: StudyFile?
    @State private var page: Page?
    @State private var allReviews = false

    enum Import: Identifiable {
        case pdf, recording
        var id: Self { self }
    }

    enum Page: Hashable {
        case introduction(String), topic(NotebookTopic), formulas, exercises, mocks, lectures, files
    }

    private var topics: [NotebookTopic] { notebook?.topics ?? [] }
    private var written: [NotebookTopic] { topics.filter { $0.written == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBlock(course.title) {
                    Text(summary).foregroundStyle(.secondary)
                    if let exam = course.nextExam, let date = Wire.parse(exam.date) { ExamTag(date: date, title: exam.title) }
                }
                if let error { ErrorCard(text: error) }
                if let busy {
                    HStack(spacing: 10) { ProgressView(); Text(busy).foregroundStyle(.secondary) }.card()
                }
                if let note {
                    Label(note.text, systemImage: note.symbol).font(.footnote).foregroundStyle(.secondary).card()
                }
                if notebook?.started == true, !written.isEmpty { practiceChips }
                ForEach(notebook?.proposals ?? []) { ProposalCard(proposal: $0, act: act).card() }
                if let pause = writer?.paused, pause.course == nil || pause.course == course.id {
                    WriterPauseCard(pause: pause) { writer = $0 }.card()
                }
                if let writing = notebook?.writing {
                    WritingRow(progress: writing.progress, step: notebook?.step).card()
                } else if notebook?.busy == true {
                    // A job with no proposal yet: the outline at the start, or new material and figures later.
                    WritingRow(title: topics.isEmpty ? "Reading the course's files" : "Working on the notebook",
                               systemImage: "books.vertical", progress: nil, step: notebook?.step).card()
                }
                knowledge
                if !reviews.isEmpty { reviewsCard }
                moreCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .previewAnchor()
        .pageGlow(Theme.study)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $page) { destination($0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add a PDF", systemImage: "doc.badge.plus") { importing = .pdf }
                    Button("Add a recording", systemImage: "waveform.badge.plus") { importing = .recording }
                    if !topics.isEmpty {
                        Button("Find figures in the slides", systemImage: "photo.on.rectangle") {
                            Task { await findFigures() }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(busy != nil)
            }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .recording ? [.audio, .mpeg4Audio, .mp3, .wav] : [.pdf]) { result in
            let kind = importing
            guard case .success(let url) = result, let kind else { return }
            Task { await upload(url, kind: kind) }
        }
        .sheet(item: $openFile) { PDFSheet(file: $0) }
        .fullScreenCover(isPresented: $showPractice, onDismiss: { Task { await load() } }) {
            PracticeExamView(course: course.id, courseName: course.name)
        }
        .confirmationDialog("Start the notebook?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start") { Task { await start() } }
        } message: {
            Text("Professor reads the course's files, writes an Introduction on the exam and proposes the topics. "
                 + "You OK the topics before anything is written. Writing them all costs about $1–1.50.")
        }
        .task { await load() }
        .refreshable { await load() }
        .task(id: "\(notebook?.writing?.id ?? "")\(notebook?.busy == true)") {
            // While Professor works, follow the progress; the result lands in the course's chat too.
            func working() -> Bool { notebook?.writing != nil || notebook?.busy == true }
            guard working() else { return }
            while !Task.isCancelled, working() {
                try? await Task.sleep(for: .seconds(4))
                if let fresh = try? await env.api.notebookPage(course: course.id) { notebook = fresh }
                if let fresh = try? await env.api.notesWriter() { writer = fresh }
            }
        }
    }

    /// "11 topics · 59 questions · 33 files".
    private var summary: String {
        var parts: [String] = []
        if !written.isEmpty { parts.append(written.count == 1 ? "1 topic" : "\(written.count) topics") }
        let questions = bank?.questions ?? written.reduce(0) { $0 + ($1.questions ?? 0) }
        if questions > 0 { parts.append("\(questions) questions") }
        if !lectures.isEmpty { parts.append(lectures.count == 1 ? "1 lecture" : "\(lectures.count) lectures") }
        if !files.isEmpty { parts.append(files.count == 1 ? "1 file" : "\(files.count) files") }
        return parts.isEmpty ? (notebook == nil ? " " : "Nothing here yet") : parts.joined(separator: " · ")
    }

    // MARK: Practice

    /// Quiz me, the practice exam, the formula sheet, the exercises and the mock exams, in a row.
    private var practiceChips: some View {
        let exercises = notebook?.exercises ?? 0, mocks = notebook?.mocks ?? 0
        let questions = written.contains { ($0.questions ?? 0) > 0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if questions {
                    Chip(title: "Quiz me", systemImage: "waveform", style: .prominent, tint: Theme.study) {
                        Task { await openChat(quiz: true) }
                    }
                    Chip(title: "Practice exam", systemImage: "checklist") { showPractice = true }
                }
                if (notebook?.formulas ?? 0) > 0 {
                    Chip(title: "Formulas", systemImage: "function") { page = .formulas }
                }
                if exercises > 0 {
                    Chip(title: "Exercises", systemImage: "pencil.and.ruler") { page = .exercises }
                } else {
                    Chip(title: "Write exercises", systemImage: "pencil.and.ruler") { Task { await writeExercises() } }
                        .disabled(notebook?.busy == true)
                }
                if mocks > 0 {
                    Chip(title: "Mock exams", systemImage: "doc.text.magnifyingglass") { page = .mocks }
                } else {
                    Chip(title: "Write a mock exam", systemImage: "doc.text.magnifyingglass") { Task { await writeMock() } }
                        .disabled(notebook?.busy == true)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    // MARK: How well you know it

    /// Each topic's questions and flashcards by how their last answer went, from the bank or the Study brief.
    private func mastery(_ topic: NotebookTopic) -> TopicMastery? {
        if let t = bank?.topics.first(where: { $0.id == topic.id }) {
            return TopicMastery(id: t.id, title: t.title, known: t.known ?? 0, learning: t.learning ?? 0, unseen: t.unseen ?? 0)
        }
        return course.notebook?.mastery?.first { $0.id == topic.id }
    }

    @ViewBuilder private var knowledge: some View {
        if let notebook, notebook.started == true {
            let rows = written.compactMap(mastery)
            DetailCard(written.isEmpty ? "Notebook" : "How well you know it", note: notebook.exam, padding: 0) {
                if !rows.isEmpty {
                    MasteryBar(topics: rows).padding(16)
                    RowDivider(leading: 16)
                }
                if let intro = notebook.introduction, !intro.isEmpty {
                    Button { page = .introduction(intro) } label: {
                        LinkRow(title: "Introduction", detail: "The exam, how it's marked, the dates", icon: "graduationcap")
                    }
                    .buttonStyle(RowPress())
                }
                ForEach(topics) { topic in
                    RowDivider(leading: 16)
                    if topic.written == true {
                        Button { page = .topic(topic) } label: { CourseTopicRow(topic: topic, mastery: mastery(topic)) }
                            .buttonStyle(RowPress())
                    } else {
                        CourseTopicRow(topic: topic, mastery: nil)
                    }
                }
            }
        } else if notebook != nil {
            DetailCard("Notebook", note: "Notes by topic, built from this course's files and lectures, with exam-style "
                       + "questions and flashcards.") {
                Chip(title: "Start the notebook", systemImage: "book", style: .prominent, tint: Theme.study) { confirmStart = true }
                    .disabled(files.isEmpty && lectures.isEmpty)
            }
        }
    }

    private var reviewsCard: some View {
        DetailCard("Review sessions", note: "In your calendar. Professor offers a quiz on the topics when one starts. "
                   + "Press and hold one to cancel it.", padding: 0) {
            ForEach(Array((allReviews ? reviews : Array(reviews.prefix(3))).enumerated()), id: \.element.id) { index, session in
                if index > 0 { RowDivider() }
                StatusRow(Wire.parse(session.start).map { StudyDay.when($0) } ?? "Review",
                          detail: (["\(session.minutes) min"] + session.topics).joined(separator: " · ")) {
                    Image(systemName: "calendar").font(.title3).foregroundStyle(Theme.study)
                }
                .contextMenu {
                    Button("Cancel the session", systemImage: "calendar.badge.minus", role: .destructive) {
                        Task { await cancel(session) }
                    }
                }
            }
            if reviews.count > 3, !allReviews {
                RowDivider()
                Button { withAnimation { allReviews = true } } label: {
                    Text("\(reviews.count - 3) more").font(.subheadline.weight(.medium)).foregroundStyle(Theme.study)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowPress())
            }
        }
    }

    private var moreCard: some View {
        VStack(spacing: 0) {
            Button { Task { await openChat() } } label: {
                LinkRow(title: "Ask Professor", icon: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(RowPress())
            if !lectures.isEmpty {
                RowDivider(leading: 56)
                Button { page = .lectures } label: { LinkRow(title: "Lectures", value: "\(lectures.count)", icon: "waveform") }
                    .buttonStyle(RowPress())
            }
            if !files.isEmpty {
                RowDivider(leading: 56)
                Button { page = .files } label: { LinkRow(title: "Files", value: "\(files.count)", icon: "doc.richtext") }
                    .buttonStyle(RowPress())
            }
        }
        .card(padding: 0)
    }

    @ViewBuilder private func destination(_ page: Page) -> some View {
        switch page {
        case .introduction(let markdown): NotePage(title: "Introduction", markdown: markdown)
        case .topic(let topic): TopicPageView(topic: topic)
        case .formulas:
            LoadedNotePage(title: "Formulas", subtitle: "Every topic's formulas, in the notebook's order") {
                try await env.api.formulas(course: course.id)
            }
        case .exercises: ExercisesView(course: course, topics: topics)
        case .mocks: MockExamsView(course: course)
        case .lectures: CourseLecturesView(lectures: lectures)
        case .files: CourseFilesView(files: files)
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            async let nb = env.api.notebookPage(course: course.id)
            async let ls = env.api.lectures(course: course.id)
            async let fs = env.api.files(course: course.id)
            (notebook, lectures, files) = try await (nb, ls, fs)
            reviews = (try? await env.api.reviewSessions(course: course.id)) ?? [] // an older server has none
            if notebook?.started == true { bank = try? await env.api.quizBank(course: course.id) }
            writer = try? await env.api.notesWriter()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func act(_ proposal: NotebookProposal, apply: Bool) async {
        do {
            if apply {
                _ = try await env.api.applyProposal(proposal.id, items: nil)
            } else {
                _ = try await env.api.declineProposal(proposal.id)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func findFigures() async {
        do {
            notebook = try await env.api.findFigures(course: course.id)
            note = ("Professor is looking at every slide. New figures go into the topics, and a note comes in the "
                    + "course chat.", "photo.on.rectangle")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func writeExercises() async {
        do {
            notebook = try await env.api.writeExercises(course: course.id)
            note = ("Professor is writing exercises for every topic. The result comes in the course chat.", "pencil.and.ruler")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func writeMock() async {
        do {
            notebook = try await env.api.writeMock(course: course.id)
            note = ("Professor is writing a mock exam like the real one. It comes in the course chat.",
                    "doc.text.magnifyingglass")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() async {
        do {
            notebook = try await env.api.startNotebook(course: course.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The course's chat, asked for when it has none yet.
    static func chat(for course: StudyCourse, api: APIClient) async throws -> String {
        if let chat = course.chat { return chat }
        return try await api.courseChat(course.id)
    }

    /// The course chat; `quiz`: with Professor quizzing out loud.
    private func openChat(quiz: Bool = false) async {
        do {
            let id = try await Self.chat(for: course, api: env.api)
            push.route = quiz ? .quiz(id) : .conversation(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel(_ session: ReviewSession) async {
        do {
            try await env.api.cancelReviewSession(session.id)
            withAnimation { reviews.removeAll { $0.id == session.id } }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func upload(_ url: URL, kind: Import) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        busy = kind == .pdf ? "Uploading \(url.lastPathComponent)…" : "Uploading the recording…"
        defer { busy = nil }
        do {
            switch kind {
            case .pdf:
                _ = try await env.api.uploadPDF(url, name: url.lastPathComponent, course: course.id)
            case .recording:
                let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
                _ = try await env.api.uploadRecording(url, type: Self.audioType(url), course: course.id, recordedAt: made)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The Content-Type the server takes for a recording, by its extension.
    static func audioType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aac": "audio/aac"
        case "mp4": "audio/mp4"
        default: "audio/m4a"
        }
    }
}

/// A row in a card that opens something: an icon in Professor's colour, the title, a count, the chevron.
private struct LinkRow: View {
    let title: String
    var detail: String?
    var value: String?
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(Theme.study).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if let value { Text(value).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// The course's questions and flashcards in one bar, known, being learnt and not tried, with the counts under it.
private struct MasteryBar: View {
    let topics: [TopicMastery]

    var body: some View {
        let known = topics.reduce(0) { $0 + $1.known }, learning = topics.reduce(0) { $0 + $1.learning }
        let unseen = topics.reduce(0) { $0 + $1.unseen }, total = max(1, known + learning + unseen)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach([(known, TopicMastery.Level.known), (learning, .learning), (unseen, .unseen)], id: \.1) { count, level in
                        if count > 0 {
                            Rectangle().fill(level.color).frame(width: max(4, g.size.width * Double(count) / Double(total) - 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                legend(known, "known", .known)
                legend(learning, "learning", .learning)
                legend(unseen, "not tried", .unseen)
            }
            .font(.footnote)
        }
    }

    private func legend(_ count: Int, _ label: String, _ level: TopicMastery.Level) -> some View {
        HStack(spacing: 5) {
            Circle().fill(level.color).frame(width: 8, height: 8)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct CourseTopicRow: View {
    let topic: NotebookTopic
    let mastery: TopicMastery?

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(mastery?.level.color ?? Color.primary.opacity(0.12)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).foregroundStyle(topic.written == true ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if topic.written == true {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var detail: String {
        guard topic.written == true else { return "Not written yet" }
        var parts: [String] = []
        if let q = topic.questions, q > 0 { parts.append(q == 1 ? "1 question" : "\(q) questions") }
        if let c = topic.cards, c > 0 { parts.append(c == 1 ? "1 flashcard" : "\(c) flashcards") }
        if let m = mastery, m.known + m.learning > 0 { parts.append("\(m.known) of \(m.total) known") }
        return parts.isEmpty ? "Notes" : parts.joined(separator: " · ")
    }
}

/// A course's lectures, each opening its notes.
private struct CourseLecturesView: View {
    let lectures: [Lecture]

    var body: some View {
        List(lectures) { lecture in
            NavigationLink {
                LectureView(lecture: lecture)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lecture.title ?? "Lecture").lineLimit(2)
                    Text(lecture.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Lectures")
    }
}

/// A course's files, each opening as a PDF.
private struct CourseFilesView: View {
    let files: [StudyFile]
    @State private var open: StudyFile?

    var body: some View {
        List(files) { file in
            Button { open = file } label: {
                HStack {
                    Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).foregroundStyle(.primary).lineLimit(2)
                        Text(detail(file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Files")
        .sheet(item: $open) { PDFSheet(file: $0) }
    }

    private func detail(_ file: StudyFile) -> String {
        [file.section.flatMap { $0.isEmpty ? nil : $0 }, file.pages.map { "\($0) pages" }, file.scanned == true ? "scan" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A course's exercises, a set per topic, each opening with its solutions folded.
struct ExercisesView: View {
    let course: StudyCourse
    /// The notebook's topics: the written ones without a set can have one written.
    let topics: [NotebookTopic]
    @EnvironmentObject private var env: AppEnvironment
    @State private var sets: [ExerciseSet]?
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let note {
                Label(note, systemImage: "pencil.and.ruler").font(.footnote).foregroundStyle(.secondary)
            }
            if let sets {
                Section {
                    ForEach(sets) { set in
                        NavigationLink {
                            LoadedNotePage(title: set.topic.title, subtitle: detail(set)) {
                                try await env.api.exercises(set.id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.topic.title)
                                Text(detail(set)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Write again") { Task { await write([set.topic.id]) } }.tint(Theme.toggle)
                        }
                    }
                } footer: {
                    Text("Try each before opening its solution. Swipe a topic to have its exercises written again.")
                }
                if !missing.isEmpty {
                    Section {
                        Button { Task { await write(missing.map(\.id)) } } label: {
                            Label("Write exercises for \(missing.count) more topic\(missing.count == 1 ? "" : "s")",
                                  systemImage: "plus")
                        }
                    } footer: {
                        Text(missing.map(\.title).joined(separator: " · "))
                    }
                }
            } else if error == nil {
                SkeletonSections(sections: 1, rows: 4, mark: false)
            }
        }
        .navigationTitle("Exercises")
        .task { await load() }
        .refreshable { await load() }
    }

    private var missing: [NotebookTopic] {
        let have = Set((sets ?? []).map(\.topic.id))
        return topics.filter { $0.written == true && !have.contains($0.id) }
    }

    private func detail(_ set: ExerciseSet) -> String {
        let count = set.count ?? 0
        var parts = ["\(count) exercise\(count == 1 ? "" : "s")"]
        if let own = set.fromMaterial, own > 0 { parts.append("\(own) from the course's sheets") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            sets = try await env.api.exerciseSets(course: course.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func write(_ topics: [String]) async {
        do {
            _ = try await env.api.writeExercises(course: course.id, topics: topics)
            note = "Professor is writing them. The result comes in the course chat."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A course's mock exams (docs/API.md, "Mock exams"): each opens to be taken like the real exam.
struct MockExamsView: View {
    let course: StudyCourse
    @EnvironmentObject private var env: AppEnvironment
    @State private var mocks: [MockExam]?
    @State private var taking: MockExam?
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let note {
                Label(note, systemImage: "doc.text.magnifyingglass").font(.footnote).foregroundStyle(.secondary)
            }
            if let mocks {
                let papers = mocks.filter { $0.source != nil }, written = mocks.filter { $0.source == nil }
                if !papers.isEmpty {
                    Section {
                        ForEach(papers) { row($0) }
                    } header: {
                        Text("From the course")
                    } footer: {
                        Text("The course's own papers, copied as they are, with the answers worked out. Also in "
                             + "Obsidian, under Past exams.")
                    }
                }
                if !written.isEmpty {
                    Section {
                        ForEach(written) { row($0) }
                    } header: {
                        if !papers.isEmpty { Text("Written by Aide") }
                    } footer: {
                        Text("Like the real exam: its questions, time and scoring. Also in Obsidian, with the answers "
                             + "at the end, to do on paper.")
                    }
                }
                Section {
                    Button { Task { await write() } } label: {
                        Label(mocks.isEmpty ? "Write a mock exam" : "Write another", systemImage: "plus")
                    }
                } footer: {
                    Text("A new one asks other questions, over every topic.")
                }
            } else if error == nil {
                SkeletonSections(sections: 1, rows: 2, mark: false)
            }
        }
        .navigationTitle("Mock exams")
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $taking, onDismiss: { Task { await load() } }) { mock in
            PracticeExamView(course: course.id, courseName: course.name, mock: mock)
        }
    }

    private func row(_ mock: MockExam) -> some View {
        Button { taking = mock } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mock.title).foregroundStyle(.primary)
                    Text(detail(mock)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let best = mock.best {
                    Text("\(best.points) / \(mock.points.points)").font(.subheadline).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ mock: MockExam) -> String {
        var parts = [mock.open > 0 ? "\(mock.mcq) multiple choice, \(mock.open) open" : "\(mock.count) questions"]
        if let minutes = mock.minutes { parts.append("\(minutes) min") }
        if let taken = mock.taken, taken > 0 { parts.append(taken == 1 ? "taken once" : "taken \(taken) times") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            mocks = try await env.api.mocks(course: course.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func write() async {
        do {
            _ = try await env.api.writeMock(course: course.id)
            note = "Professor is writing it. It comes in the course chat, and here."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TopicRow: View {
    let topic: NotebookTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(topic.position). \(topic.title)")
            if let summary = topic.summary, !summary.isEmpty {
                Text(summary.markdown).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// A proposal from Professor: what it would write, with Apply and Not now.
private struct ProposalCard: View {
    let proposal: NotebookProposal
    let act: (NotebookProposal, Bool) async -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(proposal.kind == "outline" ? "The topics, to write" : "New material", systemImage: "sparkles")
                .font(.headline)
            if let material = proposal.material, !material.isEmpty {
                Text("From " + material.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(proposal.items ?? []) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.n). \(item.title)").font(.subheadline.weight(.semibold))
                        + Text(item.topic == nil ? "  new" : "").font(.caption.weight(.semibold)).foregroundColor(Theme.toggle)
                    if let add = item.add, !add.isEmpty {
                        Text(add.markdown).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    run(true)
                } label: {
                    Text("Apply").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
                Button {
                    run(false)
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(working)
            .padding(.top, 4)
            Text("For only some of them, or with a note, answer in the chat.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func run(_ apply: Bool) {
        working = true
        Task {
            await act(proposal, apply)
            working = false
        }
    }
}

private struct WritingRow: View {
    var title = "Writing the notes"
    var systemImage = "pencil.and.scribble"
    let progress: NotebookProgress?
    /// What Professor is doing now, from the server.
    var step: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)).tint(Theme.toggle)
                Text("\(progress.done) of \(progress.total) topics").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let step, !step.isEmpty {
                Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .contentTransition(.numericText()).animation(.default, value: step)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Who writes the notes (docs/API.md, "Who writes the notes")

/// Settings → Claude plan: what runs on it (through Claude Code on the server) instead of OpenRouter, the notes
/// and the background work each on its own switch, and the plan's use.
struct NotesWriterView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var writer: NotesWriter?
    @State private var error: String?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let writer {
                if let paused = writer.paused {
                    Section { WriterPauseCard(pause: paused) { self.writer = $0 } }
                }
                Section {
                    Picker("Write notes with", selection: Binding(get: { writer.engine }, set: { new in
                        Task { await set(new) }
                    })) {
                        Text("Your Claude plan").tag("claude")
                        Text("OpenRouter").tag("openrouter")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(writer.available == false)
                } header: {
                    Text("Notes")
                } footer: {
                    Text(writer.available == false
                         ? "Claude Code isn't installed on the server, so everything goes through OpenRouter."
                         : "Lecture notes, notebook pages and the slide scan. With your plan, Sonnet writes and Haiku "
                           + "reads, with no extra cost; when its limit is reached, Professor asks whether to wait or "
                           + "finish on OpenRouter (paid).")
                }
                if writer.background != nil {
                    Section {
                        Toggle("On your Claude plan", isOn: Binding(get: { writer.backgroundOnPlan }, set: { on in
                            Task { await setBackground(on ? "claude" : "openrouter") }
                        }))
                        .tint(Theme.toggle)
                        .disabled(writer.available == false)
                    } header: {
                        Text("Background work")
                    } footer: {
                        Text("Routines and watches, digests, mail drafts, chat titles and objectives. When the plan's "
                             + "limit is reached they carry on through OpenRouter (paid) until it resets, without "
                             + "asking. Chat always uses OpenRouter.")
                    }
                }
                if let usage = writer.usage {
                    Section("Your plan") {
                        if let w = usage.fiveHour { UsageRow(title: "5-hour window", window: w) }
                        if let w = usage.sevenDay { UsageRow(title: "This week", window: w) }
                    }
                }
                if let until = writer.openrouterUntil.flatMap(Wire.parse) {
                    Section {
                        Text("On OpenRouter until \(until.formatted(date: .omitted, time: .shortened)), when the plan resets.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Your Claude plan")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { writer = try await env.api.notesWriter(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func set(_ engine: String) async {
        do { writer = try await env.api.setNotesWriter(engine); error = nil } catch { self.error = error.localizedDescription }
    }

    private func setBackground(_ engine: String) async {
        do { writer = try await env.api.setBackgroundWorker(engine); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct UsageRow: View {
    let title: String
    let window: PlanWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(((window.used ?? 0) * 100).rounded()))% used").foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(window.used ?? 0, 0), 1)).tint((window.used ?? 0) > 0.85 ? .orange : Theme.toggle)
            if let resets = window.resets {
                Text("Resets \(resets.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A notes job paused on the plan's limit: wait for the reset, or finish on OpenRouter until then.
struct WriterPauseCard: View {
    let pause: WriterPause
    let answered: (NotesWriter) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your Claude plan's limit is reached", systemImage: "pause.circle").font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button("Wait for reset") { Task { await decide("wait") } }
                    .buttonStyle(.bordered)
                Button("Finish on OpenRouter") { Task { await decide("openrouter") } }
                    .buttonStyle(.borderedProminent).tint(Theme.toggle)
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let when = pause.resets.map { " It resets \($0.formatted(.relative(presentation: .named)))." } ?? ""
        return "The notes being written are paused." + when + " OpenRouter is paid."
    }

    private func decide(_ use: String) async {
        busy = true
        defer { busy = false }
        do { answered(try await env.api.decideWriter(use)) } catch { self.error = error.localizedDescription }
    }
}
