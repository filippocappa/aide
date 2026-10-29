import SwiftUI
import UniformTypeIdentifiers

/// The Study tab: the courses, each with its notebook, lectures and files (docs/API.md, "Study", "Notebook").
struct StudyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var overview: StudyOverview?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
                if let now = overview?.now {
                    Section {
                        Label("\(now.name.prefix(1).uppercased() + now.name.dropFirst()) is on now", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Theme.toggle)
                    }
                }
                if let courses = overview?.courses {
                    Section {
                        ForEach(courses) { course in
                            NavigationLink(value: course) { CourseRow(course: course) }
                        }
                    } footer: {
                        if courses.isEmpty { Text("Courses come from the timetable calendar.") }
                    }
                } else if error == nil {
                    SkeletonSections(sections: 1, rows: 3, mark: false)
                }
            }
            .navigationTitle("Study")
            .navigationDestination(for: StudyCourse.self) { CourseView(course: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Moodle", systemImage: "building.columns") { env.showMoodle = true }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            overview = try await env.api.study()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CourseRow: View {
    let course: StudyCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let exam = course.nextExam, let date = Wire.parse(exam.date) {
                Label("Exam \(date.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if let nb = course.notebook {
            // Started with nothing to show or answer yet: the outline is being drafted.
            let drafting = nb.topics == 0 && (nb.proposals ?? 0) == 0
            parts.append(nb.writing == true ? "Notes being written" : drafting ? "Topics being drafted" : "\(nb.topics) topics")
            if let p = nb.proposals, p > 0 { parts.append(p == 1 ? "1 to answer" : "\(p) to answer") }
        }
        if let n = course.lectures, n > 0 { parts.append(n == 1 ? "1 lecture" : "\(n) lectures") }
        if let n = course.files, n > 0 { parts.append(n == 1 ? "1 file" : "\(n) files") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }
}

/// A course: what's waiting for an answer, the notebook, practice, lectures and files.
struct CourseView: View {
    let course: StudyCourse
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @State private var notebook: NotebookStatus?
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

    enum Import: Identifiable {
        case pdf, recording
        var id: Self { self }
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let busy {
                HStack(spacing: 10) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
            }
            if let note {
                Label(note.text, systemImage: note.symbol).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(notebook?.proposals ?? []) { proposal in
                Section { ProposalCard(proposal: proposal, act: act) }
            }
            if let pause = writer?.paused, pause.course == nil || pause.course == course.id {
                Section { WriterPauseCard(pause: pause) { writer = $0 } }
            }
            if let writing = notebook?.writing {
                Section { WritingRow(progress: writing.progress, step: notebook?.step) }
            } else if notebook?.busy == true {
                // A job with no proposal yet: the outline at the start, or new material and figures later.
                Section {
                    WritingRow(title: (notebook?.topics ?? []).isEmpty ? "Reading the course's files"
                                                                        : "Working on the notebook",
                               systemImage: "books.vertical", progress: nil, step: notebook?.step)
                }
            }
            notebookSection
            practiceSection
            Section {
                Button { Task { await openChat() } } label: {
                    Label("Ask Professor", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            if !reviews.isEmpty {
                Section {
                    ForEach(reviews) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reviewTime(session))
                            if !session.topics.isEmpty {
                                Text(session.topics.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Cancel", role: .destructive) { Task { await cancel(session) } }
                        }
                    }
                } header: {
                    Text("Review sessions")
                } footer: {
                    Text("In your calendar. Professor offers a quiz on the topics when one starts.")
                }
            }
            if !lectures.isEmpty {
                Section("Lectures") {
                    ForEach(lectures) { lecture in
                        NavigationLink {
                            LectureView(lecture: lecture)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lecture.title ?? "Lecture").lineLimit(2)
                                Text(lecture.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files) { file in
                        Button { openFile = file } label: {
                            HStack {
                                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(fileDetail(file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(course.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add a PDF", systemImage: "doc.badge.plus") { importing = .pdf }
                    Button("Add a recording", systemImage: "waveform.badge.plus") { importing = .recording }
                    if !(notebook?.topics ?? []).isEmpty {
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

    @ViewBuilder private var notebookSection: some View {
        if let notebook, notebook.started == true {
            Section {
                if let intro = notebook.introduction, !intro.isEmpty {
                    NavigationLink {
                        NotePage(title: "Introduction", markdown: intro)
                    } label: {
                        Label("Introduction", systemImage: "graduationcap")
                    }
                }
                ForEach(notebook.topics ?? []) { topic in
                    if topic.written == true {
                        NavigationLink { TopicPageView(topic: topic) } label: { TopicRow(topic: topic) }
                    } else {
                        TopicRow(topic: topic).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Notebook")
            } footer: {
                if let exam = notebook.exam { Text(exam) }
            }
        } else if notebook != nil {
            Section {
                Button { confirmStart = true } label: { Label("Start the notebook", systemImage: "book") }
                    .disabled(files.isEmpty && lectures.isEmpty)
            } footer: {
                Text("Notes by topic, built from this course's files and lectures, with exam-style questions and flashcards.")
            }
        }
    }

    /// The formula sheet, the exercises, quizzes and practice exams: once some topic is written.
    @ViewBuilder private var practiceSection: some View {
        if let notebook, notebook.started == true, (notebook.topics ?? []).contains(where: { $0.written == true }) {
            let exercises = notebook.exercises ?? 0
            Section {
                if (notebook.formulas ?? 0) > 0 {
                    NavigationLink {
                        LoadedNotePage(title: "Formulas", subtitle: "Every topic's formulas, in the notebook's order") {
                            try await env.api.formulas(course: course.id)
                        }
                    } label: {
                        Label("Formulas", systemImage: "function")
                    }
                }
                if exercises > 0 {
                    NavigationLink {
                        ExercisesView(course: course, topics: notebook.topics ?? [])
                    } label: {
                        Label("Exercises", systemImage: "pencil.and.ruler")
                    }
                    .badge(exercises)
                } else {
                    Button { Task { await writeExercises() } } label: {
                        Label("Write exercises", systemImage: "pencil.and.ruler")
                    }
                    .disabled(notebook.busy == true)
                }
                if (notebook.topics ?? []).contains(where: { ($0.questions ?? 0) > 0 }) {
                    Button { Task { await openChat(quiz: true) } } label: { Label("Quiz me", systemImage: "waveform") }
                    Button { showPractice = true } label: { Label("Practice exam", systemImage: "checklist") }
                }
                if (notebook.mocks ?? 0) > 0 {
                    NavigationLink {
                        MockExamsView(course: course)
                    } label: {
                        Label("Mock exams", systemImage: "doc.text.magnifyingglass")
                    }
                    .badge(notebook.mocks ?? 0)
                } else {
                    Button { Task { await writeMock() } } label: {
                        Label("Write a mock exam", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(notebook.busy == true)
                }
            } header: {
                Text("Practice")
            } footer: {
                if exercises == 0 {
                    Text("Professor copies the course's own exercise sheets and past exams and solves them step by "
                         + "step, following the course's solutions where it has them.")
                } else if (notebook.mocks ?? 0) == 0 {
                    Text("A mock exam is a paper like the real one, open questions included, timed and marked.")
                }
            }
        }
    }

    private func fileDetail(_ file: StudyFile) -> String {
        [file.section.flatMap { $0.isEmpty ? nil : $0 }, file.pages.map { "\($0) pages" }, file.scanned == true ? "scan" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        do {
            async let nb = env.api.notebookPage(course: course.id)
            async let ls = env.api.lectures(course: course.id)
            async let fs = env.api.files(course: course.id)
            (notebook, lectures, files) = try await (nb, ls, fs)
            reviews = (try? await env.api.reviewSessions(course: course.id)) ?? [] // an older server has none
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

    /// The course chat; `quiz`: with Professor quizzing out loud.
    private func openChat(quiz: Bool = false) async {
        do {
            let id: String
            if let chat = course.chat { id = chat } else { id = try await env.api.courseChat(course.id) }
            push.route = quiz ? .quiz(id) : .conversation(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reviewTime(_ session: ReviewSession) -> String {
        guard let start = Wire.parse(session.start) else { return "\(session.minutes) min" }
        return "\(start.formatted(.dateTime.weekday(.wide).day().month().hour().minute())), \(session.minutes) min"
    }

    private func cancel(_ session: ReviewSession) async {
        do {
            try await env.api.cancelReviewSession(session.id)
            reviews.removeAll { $0.id == session.id }
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
