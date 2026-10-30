import SwiftUI

/// A practice exam from a course's notebook (docs/API.md, "Practice exams"): how many questions and whether it's
/// timed, then a question a page, then the score the exam would give and every explanation. Professor posts the
/// result in the course's chat. With `mock`, that mock exam ("Mock exams"): its time and scoring, open questions
/// answered in words or photos of the work, and marked after.
struct PracticeExamView: View {
    let course: Int
    var courseName: String?
    var mock: MockExam?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var bank: QuizBank?
    @State private var quiz: Quiz?
    @State private var result: Quiz?
    @State private var error: String?
    @State private var starting = false
    @State private var count = 30
    @State private var timed = true
    @State private var minutes = 45

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    PracticeResults(quiz: result)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                        .task(id: result.id) { await followMarking() }
                } else if let quiz {
                    PracticeTaking(quiz: quiz, error: error, finish: finish, quit: { dismiss() })
                } else {
                    setup
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(quiz != nil && result == nil)
    }

    // MARK: Setup

    private var setup: some View {
        Form {
            if let mock {
                mockSection(mock)
            } else if let bank {
                if bank.questions == 0 {
                    Section {
                        Text("No questions yet. They come with the notebook's topic pages.").foregroundStyle(.secondary)
                    }
                } else {
                    startSection(bank)
                    Section {
                        LabeledContent("In the notes", value: "\(bank.questions)")
                        LabeledContent("Not seen yet", value: "\(bank.unseen)")
                        LabeledContent("To review", value: "\(bank.toReview)")
                    } footer: {
                        Text("Questions you got wrong or left blank come back first, then new ones.")
                    }
                    if !bank.past.isEmpty { pastSection(bank.past) }
                }
            } else if error == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(mock?.title ?? courseName.map { "Practice · \($0)" } ?? "Practice exam")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { if mock == nil { await load() } }
    }

    private func mockSection(_ mock: MockExam) -> some View {
        Section {
            LabeledContent("Questions", value: "\(mock.count)")
            if mock.mcq > 0 { LabeledContent("Multiple choice", value: "\(mock.mcq)") }
            if mock.open > 0 { LabeledContent("Open", value: "\(mock.open)") }
            LabeledContent("Points", value: mock.points.points)
            LabeledContent("Time", value: mock.minutes.map { "\($0) min" } ?? "Untimed")
            Button {
                Task { await start() }
            } label: {
                HStack {
                    Text("Start").fontWeight(.semibold)
                    if starting { Spacer(); ProgressView() }
                }
            }
            .disabled(starting)
        } footer: {
            Text(Self.rules(mock))
        }
    }

    /// How a mock is scored and marked, for its setup's footer.
    static func rules(_ mock: MockExam) -> String {
        var lines = ["Like the real exam: the clock runs from Start and hands it in when time's up."]
        if mock.mcq > 0, let s = mock.scoring {
            lines.append(s.wrong == 0 ? "Multiple choice: right +\(s.right.points), no penalty for a wrong answer."
                         : "Multiple choice: right +\(s.right.points), wrong \(s.wrong.points), blank \((s.blank ?? 0).points).")
        }
        if mock.open > 0 {
            lines.append("Open questions: type your answer or photograph your work on paper. Professor marks them "
                         + "after, against a model answer.")
        }
        return lines.joined(separator: "\n")
    }

    private func startSection(_ bank: QuizBank) -> some View {
        Section {
            Stepper(value: $count, in: 1...min(60, bank.questions), step: bank.questions >= 10 ? 5 : 1) {
                LabeledContent("Questions", value: "\(count)")
            }
            Toggle("Timed", isOn: $timed).tint(Theme.toggle)
            if timed {
                Stepper(value: $minutes, in: 5...240, step: 5) {
                    LabeledContent("Time", value: "\(minutes) min")
                }
            }
            Button {
                Task { await start() }
            } label: {
                HStack {
                    Text("Start").fontWeight(.semibold)
                    if starting { Spacer(); ProgressView() }
                }
            }
            .disabled(starting)
        } footer: {
            Text([bank.exam, "Scored like the exam: right +1, wrong −0.25, blank 0."].compactMap { $0 }.joined(separator: "\n"))
        }
        .onChange(of: count) { _, new in minutes = Self.minutes(for: new) }
    }

    private func pastSection(_ past: [Quiz]) -> some View {
        Section("Past") {
            ForEach(past) { quiz in
                HStack {
                    Text(quiz.finishedAt.flatMap(Wire.parse)?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                    Spacer()
                    if let score = quiz.score {
                        Text("\(score.points.points) / \(score.max.points)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A minute and a half a question, rounded to 5.
    private static func minutes(for count: Int) -> Int { max(5, Int((Double(count) * 1.5 / 5).rounded()) * 5) }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await env.api.quizBank(course: course)
            bank = loaded
            count = min(30, loaded.questions)
            minutes = Self.minutes(for: count)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            if let mock {
                quiz = try await env.api.startMock(course: course, mock: mock.id)
            } else {
                quiz = try await env.api.startQuiz(course: course, count: count, minutes: timed ? minutes : nil)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A mock's open answers are marked in the background: the result is fetched again until they are.
    private func followMarking() async {
        while let current = result, current.score?.grading == true, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
            if let fresh = try? await env.api.quiz(current.id), fresh.finishedAt != nil {
                withAnimation { result = fresh }
            }
        }
    }

    private func finish(_ answers: [Int: QuizAnswer]) async {
        guard let quiz else { return }
        do {
            let done = try await env.api.finishQuiz(quiz.id, answers: answers)
            withAnimation { result = done }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Taking it

private struct PracticeTaking: View {
    let quiz: Quiz
    let error: String?
    let finish: ([Int: QuizAnswer]) async -> Void
    let quit: () -> Void
    @State private var page = 0
    @State private var answers: [Int: String] = [:]
    /// Open questions' answers, kept as they're written.
    @State private var drafts: [Int: OpenDraft] = [:]
    @State private var deadline: Date?
    @State private var finishing = false
    @State private var confirmFinish = false
    @State private var confirmQuit = false

    private var isLast: Bool { page == quiz.questions.count - 1 }
    private var blanks: Int { quiz.questions.filter { !answered($0) }.count }
    private var uploading: Bool { drafts.values.contains { $0.uploading > 0 } }

    private func answered(_ question: QuizQuestion) -> Bool {
        question.isOpen ? drafts[question.n]?.isEmpty == false : answers[question.n] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            TabView(selection: $page) {
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                    ScrollView {
                        if question.isOpen {
                            OpenQuestionPage(question: question,
                                             draft: Binding(get: { drafts[question.n] ?? OpenDraft() },
                                                            set: { drafts[question.n] = $0 }))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        } else {
                            QuestionPage(question: question, chosen: answers[question.n]) { letter in
                                answers[question.n] = answers[question.n] == letter ? nil : letter
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 6)
            }
            controls
        }
        .background(Theme.background)
        .navigationTitle("\(page + 1) of \(quiz.questions.count)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Quit") { confirmQuit = true } }
            ToolbarItem(placement: .primaryAction) {
                if let deadline { Clock(deadline: deadline) }
            }
        }
        .confirmationDialog(quiz.kind == "mock" ? "Hand it in?" : "Finish the practice exam?", isPresented: $confirmFinish,
                            titleVisibility: .visible) {
            Button("Finish") { submit() }
        } message: {
            Text(uploading ? "A photo is still going up: wait for it, or it's left out."
                 : blanks == 0 ? "Every question has an answer."
                 : blanks == 1 ? "1 question is blank: it scores 0." : "\(blanks) questions are blank: they score 0.")
        }
        .confirmationDialog("Quit the practice exam?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit", role: .destructive) { quit() }
        } message: {
            Text("Your answers aren't kept.")
        }
        .onAppear {
            if deadline == nil, let minutes = quiz.minutes { deadline = Date().addingTimeInterval(Double(minutes) * 60) }
        }
        .task(id: deadline) {
            // Time's up: handed in as it is, like the real one.
            guard let deadline else { return }
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            if !Task.isCancelled { submit() }
        }
    }

    private var progress: some View {
        HStack(spacing: 3) {
            ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                Capsule()
                    .fill(answered(question) ? Theme.accent : Theme.chip)
                    .frame(height: index == page ? 6 : 4)
                    .onTapGesture { withAnimation { page = index } }
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { page -= 1 }
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(page == 0)
            .accessibilityLabel("Previous question")
            Spacer()
            Button {
                if isLast { confirmFinish = true } else { withAnimation { page += 1 } }
            } label: {
                HStack {
                    if finishing { ProgressView().tint(Theme.onAccent) }
                    Text(isLast ? "Finish" : "Next").fontWeight(.semibold)
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 28)
                .frame(height: 44)
                .background(Theme.accent, in: Capsule())
            }
            .disabled(finishing)
            Spacer()
            Button("Finish") { confirmFinish = true }
                .font(.subheadline)
                .frame(width: 60, height: 44)
                .opacity(isLast ? 0 : 1)
                .disabled(finishing || isLast)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func submit() {
        guard !finishing else { return }
        finishing = true
        var handed = answers.mapValues { QuizAnswer.letter($0) }
        for (n, draft) in drafts where !draft.isEmpty {
            handed[n] = .open(text: draft.text, photos: draft.photos.compactMap(\.id))
        }
        Task {
            await finish(handed)
            finishing = false
        }
    }
}

/// The time left, counting down; red in the last five minutes.
private struct Clock: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(left <= 300 ? Color.red : Color.primary)
                .accessibilityLabel("\(left / 60) minutes left")
        }
    }
}

private struct QuestionPage: View {
    let question: QuizQuestion
    let chosen: String?
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.topic.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(question.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            VStack(spacing: 10) {
                ForEach(question.options, id: \.letter) { option in
                    Button { choose(option.letter) } label: {
                        OptionRow(option: option, state: chosen == option.letter ? .chosen : .plain)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(chosen == nil ? "Leave it blank if you'd rather not guess." : "Tap your answer again to leave it blank.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An open question's answer while it's written: the words, and photos of the work as they go up.
struct OpenDraft: Equatable {
    struct Photo: Identifiable, Equatable {
        let local = UUID()
        let jpeg: Data
        var id: String?
        var failed = false
        var key: UUID { local }
    }
    var text = ""
    var photos: [Photo] = []
    var uploading: Int { photos.filter { $0.id == nil && !$0.failed }.count }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !photos.contains { $0.id != nil } }
}

private struct OpenQuestionPage: View {
    @EnvironmentObject private var env: AppEnvironment
    let question: QuizQuestion
    @Binding var draft: OpenDraft
    @State private var camera = false
    @State private var library = false
    @FocusState private var writing: Bool

    private let most = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(question.topic.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let points = question.points {
                    Text("\(points.points) points").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(question.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            TextEditor(text: $draft.text)
                .focused($writing)
                .frame(minHeight: 180)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Your answer").foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            if !draft.photos.isEmpty { photoStrip }
            HStack(spacing: 12) {
                if CameraPicker.isAvailable {
                    Button { writing = false; camera = true } label: { Label("Camera", systemImage: "camera") }
                }
                Button { writing = false; library = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .disabled(draft.photos.count >= most)
            Text("Write it here, or work on paper and photograph it: Professor reads both.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .photoSources(camera: $camera, library: $library, limit: most - draft.photos.count) { picked in
            for photo in picked.prefix(most - draft.photos.count) { add(photo) }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.photos, id: \.key) { photo in
                    ServerPhoto(id: photo.id, local: photo.jpeg)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            if photo.failed {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                                    .padding(6).background(.red, in: Circle())
                            } else if photo.id == nil {
                                ProgressView().tint(.white).padding(6).background(.black.opacity(0.4), in: Circle())
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                draft.photos.removeAll { $0.key == photo.key }
                            } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4)
                            .accessibilityLabel("Remove the photo")
                        }
                }
            }
        }
    }

    private func add(_ picked: PickedPhoto) {
        let photo = OpenDraft.Photo(jpeg: picked.jpeg)
        draft.photos.append(photo)
        Task {
            let id = try? await env.api.uploadPhoto(picked.jpeg)
            guard let index = draft.photos.firstIndex(where: { $0.key == photo.key }) else { return }
            if let id { draft.photos[index].id = id } else { draft.photos[index].failed = true }
        }
    }
}

private struct OptionRow: View {
    enum Mark { case plain, chosen, key, wrong }
    let option: QuizOption
    let state: Mark

    var body: some View {
        HStack(spacing: 12) {
            Text(option.letter)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state == .plain ? Color.primary : .white)
                .frame(width: 28, height: 28)
                .background(badge, in: Circle())
            Text(option.text.markdown).frame(maxWidth: .infinity, alignment: .leading).lineSpacing(2)
            if state == .key { Image(systemName: "checkmark").foregroundStyle(.green) }
            if state == .wrong { Image(systemName: "xmark").foregroundStyle(.red) }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state == .plain ? Color.clear : badge, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
    }

    private var badge: Color {
        switch state {
        case .plain: Theme.chip
        case .chosen: Theme.accent
        case .key: .green
        case .wrong: .red
        }
    }
}

// MARK: Results

private struct PracticeResults: View {
    let quiz: Quiz
    /// Opened from the result's card in the course chat: no pointer back to it.
    var fromChat = false
    @State private var onlyMissed = true

    private var shown: [QuizQuestion] { onlyMissed ? quiz.questions.filter { $0.correct != true } : quiz.questions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let score = quiz.score {
                    header(score)
                    if let topics = score.topics, topics.count > 1 { byTopic(topics) }
                }
                Picker("Show", selection: $onlyMissed) {
                    Text("Missed").tag(true)
                    Text("All").tag(false)
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    Text("Nothing missed.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(shown) { ReviewCard(question: $0, grading: quiz.score?.grading == true) }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Result")
    }

    private func header(_ score: QuizScore) -> some View {
        VStack(spacing: 6) {
            Text("\(score.points.points) / \(score.max.points)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(score.right) right · \(score.wrong) wrong · \(score.blank) blank")
                .font(.subheadline).foregroundStyle(.secondary)
            if score.grading == true {
                Label {
                    Text("Professor is marking the open answers; the score counts them as 0 until then.")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            } else if !fromChat {
                Text("Professor has the result in the course's chat.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func byTopic(_ topics: [QuizTopicScore]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By topic").font(.headline)
            ForEach(topics) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(topic.title).font(.subheadline)
                        Spacer()
                        Text("\(topic.right) of \(topic.total)").font(.subheadline).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(topic.right), total: Double(max(1, topic.total)))
                        .tint(topic.right == topic.total ? Theme.toggle : Theme.accent)
                }
            }
        }
    }
}

// MARK: In the chat

/// A finished practice or mock exam in the course chat (docs/API.md, Chat, `quiz`): the score in a ring, right,
/// wrong and blank, the weakest topics; a tap opens every answer.
struct QuizResultCard: View {
    let quiz: Quiz
    @EnvironmentObject private var chat: ChatViewModel
    @State private var open = false

    /// Of the most the paper scores, 0–100 (wrong answers can take points below 0).
    private func percent(_ score: QuizScore) -> Int {
        score.max > 0 ? Int((min(max(score.points / score.max, 0), 1) * 100).rounded()) : 0
    }

    private var took: String? {
        guard let start = quiz.startedAt.flatMap(Wire.parse), let end = quiz.finishedAt.flatMap(Wire.parse) else { return nil }
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        return "\(minutes) min"
    }

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: quiz.kind == "mock" ? "doc.text.fill" : "checklist")
                    Text(quiz.title ?? "Practice exam").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if let took { Label(took, systemImage: "clock").labelStyle(.titleAndIcon) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let score = quiz.score {
                    HStack(spacing: 16) {
                        ScoreRing(score: percent(score), tint: chat.agent.tint, size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(score.points.points) / \(score.max.points)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            HStack(spacing: 12) {
                                tally(score.right, "checkmark.circle.fill", .green)
                                tally(score.wrong, "xmark.circle.fill", .red)
                                tally(score.blank, "minus.circle.fill", .secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    topics(score)
                }
                HStack(spacing: 4) {
                    Text("See every answer")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { QuizResultSheet(id: quiz.id) }
    }

    private func tally(_ count: Int, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(count)").monospacedDigit()
        }
        .font(.subheadline.weight(.medium))
    }

    /// The three weakest topics, as bars; none when every topic was right.
    @ViewBuilder private func topics(_ score: QuizScore) -> some View {
        let weak = (score.topics ?? []).filter { $0.right < $0.total }.prefix(3)
        if !weak.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(weak)) { topic in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(topic.title).lineLimit(1)
                            Spacer()
                            Text("\(topic.right) of \(topic.total)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        Capsule().fill(chat.agent.tint.opacity(0.15))
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(chat.agent.tint)
                                        .frame(width: g.size.width * Double(topic.right) / Double(max(1, topic.total)))
                                }
                            }
                            .frame(height: 5)
                    }
                }
            }
        } else if score.topics != nil {
            Label("Every topic right", systemImage: "star.fill").font(.footnote.weight(.medium)).foregroundStyle(.green)
        }
    }
}

/// Every answer of a finished quiz, from the chat's card.
struct QuizResultSheet: View {
    let id: String
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var quiz: Quiz?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let quiz {
                    PracticeResults(quiz: quiz, fromChat: true)
                } else if let error {
                    ContentUnavailableView("Couldn't load it", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do { quiz = try await env.api.quiz(id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// A review session starting, in the course chat (docs/API.md, Chat, `review`): the course, how long, the topics,
/// and the quiz a tap away, typed or by voice.
struct ReviewStartCard: View {
    let session: ReviewSession
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var voice: VoiceController

    private var when: String? {
        Wire.parse(session.start)?.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "book.fill")
                Text("Review session").fontWeight(.semibold)
                Spacer(minLength: 0)
                Label([when, "\(session.minutes) min"].compactMap { $0 }.joined(separator: " · "), systemImage: "clock")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(session.name ?? "Review").font(.title3.weight(.bold))
            if !session.topics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.topics, id: \.self) { topic in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(chat.agent.tint).frame(width: 6, height: 6).padding(.top, 7)
                            Text(topic).font(.subheadline)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { Task { await chat.send("Quiz me") } } label: {
                    Label("Quiz me", systemImage: "questionmark.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accent, in: Capsule())
                }
                Button { Task { await voice.start(saying: "Quiz me") } } label: {
                    Label("By voice", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.background.opacity(0.6), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(chat.isSending || voice.isActive)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReviewCard: View {
    let question: QuizQuestion
    var grading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(question.n). \(question.topic.title)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if question.isOpen {
                    marks
                } else if question.answer == nil {
                    Text("Blank").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text(question.text.markdown).font(.body.weight(.medium))
            if question.isOpen { open } else { choice }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var marks: some View {
        let points = question.points ?? 0
        if question.response == nil {
            Text("Blank · 0 / \(points.points)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        } else if let awarded = question.awarded {
            Text("\(awarded.points) / \(points.points)").font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(question.correct == true ? .green : .orange)
        } else {
            Text(grading ? "Being marked" : "Not marked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var open: some View {
        if let response = question.response {
            VStack(alignment: .leading, spacing: 8) {
                if let text = response.text, !text.isEmpty {
                    Text(text).font(.subheadline)
                }
                if let photos = response.photos, !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos, id: \.self) { id in
                                ServerPhoto(id: id).frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if let feedback = question.feedback, !feedback.isEmpty {
            Text(feedback.markdown).font(.subheadline).lineSpacing(2)
        }
        if let answer = question.modelAnswer, !answer.isEmpty {
            DisclosureGroup("Model answer") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(answer.markdown).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                    if let rubric = question.rubric, !rubric.isEmpty {
                        Text("Marking").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(rubric.markdown).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.subheadline)
            .tint(Theme.accent)
        }
    }

    @ViewBuilder private var choice: some View {
        ForEach(question.options, id: \.letter) { option in
            OptionRow(option: option, state: option.letter == question.key ? .key
                      : option.letter == question.answer ? .wrong : .plain)
        }
        if let explanation = question.explanation, !explanation.isEmpty {
            Text(explanation.markdown).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
        }
    }
}

extension Double {
    /// 22.75, 30: no trailing zeros.
    var points: String { formatted(.number.precision(.fractionLength(0...2))) }
}
