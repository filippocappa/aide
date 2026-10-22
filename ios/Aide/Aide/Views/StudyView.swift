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
                    ProgressView().frame(maxWidth: .infinity)
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
    @State private var note: String?
    @State private var lectures: [Lecture] = []
    @State private var files: [StudyFile] = []
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
                Label(note, systemImage: "photo.on.rectangle").font(.footnote).foregroundStyle(.secondary)
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
            Section {
                Button { Task { await openChat() } } label: {
                    Label("Ask Professor", systemImage: "bubble.left.and.text.bubble.right")
                }
                if (notebook?.topics ?? []).contains(where: { ($0.questions ?? 0) > 0 }) {
                    Button { showPractice = true } label: { Label("Practice exam", systemImage: "checklist") }
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
            note = "Professor is looking at every slide. New figures go into the topics, and a note comes in the course chat."
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

    private func openChat() async {
        do {
            let id: String
            if let chat = course.chat { id = chat } else { id = try await env.api.courseChat(course.id) }
            push.route = .conversation(id)
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

/// Settings → Study: the user's Claude plan (through Claude Code on the server) or OpenRouter, and the plan's use.
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
                } footer: {
                    Text(writer.available == false
                         ? "Claude Code isn't installed on the server, so notes are written through OpenRouter."
                         : "Lecture notes, notebook pages and the slide scan. With your plan, Sonnet writes and Haiku "
                           + "reads, with no extra cost; when its limit is reached, Professor asks whether to wait or "
                           + "finish on OpenRouter (paid). Chat always uses OpenRouter.")
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
        .navigationTitle("Who writes the notes")
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
