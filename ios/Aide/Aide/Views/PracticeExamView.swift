import SwiftUI

/// A practice exam from a course's notebook (docs/API.md, "Practice exams"): how many questions, flashcards and the
/// course's exercises, whether it's timed, then a question a page, each answer shown as it's checked (or all at the
/// end, as Settings says), then the score the exam would give. Professor posts the result in the course's chat. With
/// `mock`, that mock exam ("Mock exams"): its time and scoring, open questions answered in words or photos of the
/// work, nothing shown before it's handed in, and marked after.
struct PracticeExamView: View {
    let course: Int
    var courseName: String?
    var mock: MockExam?
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var bank: QuizBank?
    @State private var quiz: Quiz?
    @State private var result: Quiz?
    @State private var error: String?
    @State private var starting = false
    @State private var count = 20
    @State private var cards = 0
    @State private var exercises = 0
    @State private var timed = true
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    PracticeResults(quiz: result, again: mock == nil ? { again() } : nil)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                        .task(id: result.id) { await followMarking() }
                } else if let quiz {
                    PracticeTaking(quiz: quiz, revealNow: settings.studyRevealNow && quiz.kind != "mock", error: error,
                                   check: { n, answer in try await env.api.checkQuiz(quiz.id, n: n, answer: answer) },
                                   finish: finish, quit: { dismiss() })
                } else {
                    setup
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(quiz != nil && result == nil)
        .task { previewStart() }
    }

    // MARK: Setup

    private var total: Int { count + cards + exercises }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBlock(mock?.title ?? "Practice exam", overline: courseName) {
                    Text(mock.map(Self.rules) ?? bank.map(rules) ?? " ").foregroundStyle(.secondary)
                }
                if let error { ErrorCard(text: error) }
                if let mock {
                    mockCard(mock)
                } else if let bank {
                    if bank.questions + bank.cards + bank.exercises == 0 {
                        Text("No questions yet. They come with the notebook's topic pages.").foregroundStyle(.secondary).card()
                    } else {
                        contentsCard(bank)
                        optionsCard
                        if !bank.past.isEmpty { pastCard(bank.past) }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity).card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .pageGlow(Theme.study)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .bottomBar {
            if mock != nil || (bank.map { $0.questions + $0.cards + $0.exercises } ?? 0) > 0 {
                Button { Task { await start() } } label: {
                    HStack(spacing: 8) {
                        if starting { ProgressView().tint(.white) }
                        Text(mock != nil ? "Start" : total == 1 ? "Start · 1 question" : "Start · \(total) questions")
                    }
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Theme.study, in: Capsule())
                }
                .buttonStyle(CardPress())
                .disabled(starting || (mock == nil && total == 0))
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task { if mock == nil { await load() } }
        .onChange(of: total) { minutes = Self.minutes(count: count, cards: cards, exercises: exercises) }
    }

    private func rules(_ bank: QuizBank) -> String {
        "Scored like the exam: right +1, wrong −0.25, blank 0. Flashcards you mark yourself, with no penalty. "
            + "Exercises are marked by Professor against the course's solution."
    }

    private func mockCard(_ mock: MockExam) -> some View {
        VStack(spacing: 0) {
            ValueRow(title: "Questions", value: "\(mock.count)")
            if mock.mcq > 0 { RowDivider(); ValueRow(title: "Multiple choice", value: "\(mock.mcq)") }
            if mock.open > 0 { RowDivider(); ValueRow(title: "Open", value: "\(mock.open)") }
            RowDivider()
            ValueRow(title: "Points", value: mock.points.points)
            RowDivider()
            ValueRow(title: "Time", value: mock.minutes.map { "\($0) min" } ?? "Untimed")
        }
        .card(padding: 0)
    }

    /// How a mock is scored and marked.
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
        return lines.joined(separator: " ")
    }

    private func contentsCard(_ bank: QuizBank) -> some View {
        DetailCard("In it", note: "Questions you got wrong or left blank come back first, then new ones.", padding: 0) {
            VStack(spacing: 0) {
                if bank.questions > 0 {
                    CountRow(title: "Questions", detail: questionsDetail(bank), value: $count,
                             range: 0...min(60, bank.questions), step: bank.questions >= 10 ? 5 : 1)
                }
                if bank.cards > 0 {
                    RowDivider()
                    CountRow(title: "Flashcards", detail: "\(bank.cards) in the notes", value: $cards,
                             range: 0...min(30, bank.cards), step: bank.cards >= 10 ? 5 : 1)
                }
                if bank.exercises > 0 {
                    RowDivider()
                    CountRow(title: "Exercises", detail: "\(bank.exercises) from the course's sheets", value: $exercises,
                             range: 0...min(10, bank.exercises), step: 1)
                }
            }
        }
    }

    private func questionsDetail(_ bank: QuizBank) -> String {
        var parts = ["\(bank.questions) in the notes"]
        if bank.toReview > 0 { parts.append("\(bank.toReview) to review") }
        if bank.unseen > 0 { parts.append("\(bank.unseen) not seen") }
        return parts.joined(separator: " · ")
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Timed", isOn: $timed.animation()).tint(Theme.study).padding(.horizontal, 16).padding(.vertical, 11)
            if timed {
                RowDivider()
                CountRow(title: "Time", unit: "min", value: $minutes, range: 5...240, step: 5)
            }
            RowDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Show the answers")
                Picker("Show the answers", selection: $settings.studyRevealNow) {
                    Text("After each question").tag(true)
                    Text("At the end").tag(false)
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
        }
        .card(padding: 0)
    }

    private func pastCard(_ past: [Quiz]) -> some View {
        DetailCard("Past scores", padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(past.enumerated()), id: \.element.id) { index, quiz in
                    if index > 0 { RowDivider() }
                    ValueRow(title: quiz.finishedAt.flatMap(Wire.parse)?.formatted(date: .abbreviated, time: .shortened) ?? "–",
                             value: quiz.score.map { "\($0.points.points) / \($0.max.points)" } ?? "")
                }
            }
        }
    }

    /// A minute and a half a question, half a minute a flashcard, six an exercise, rounded to 5.
    private static func minutes(count: Int, cards: Int, exercises: Int) -> Int {
        let raw = Double(count) * 1.5 + Double(cards) * 0.5 + Double(exercises) * 6
        return max(5, Int((raw / 5).rounded()) * 5)
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await env.api.quizBank(course: course)
            bank = loaded
            count = min(20, loaded.questions)
            cards = min(5, loaded.cards)
            exercises = min(2, loaded.exercises)
            minutes = Self.minutes(count: count, cards: cards, exercises: exercises)
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
                quiz = try await env.api.startQuiz(course: course, count: count, cards: cards, exercises: exercises,
                                                   minutes: timed ? minutes : nil)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Back to the setup for another one.
    private func again() {
        withAnimation {
            result = nil
            quiz = nil
            bank = nil
        }
        Task { await load() }
    }

    /// Open answers are marked in the background: the result is fetched again until they are.
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

    /// Simulator screenshots: `-previewExam start` starts one straight away (with every kind of question in it),
    /// `-previewExam result:x_…` shows a finished one.
    private func previewStart() {
        #if DEBUG
        guard env.settings.isPreview, let what = UserDefaults.standard.string(forKey: "previewExam") else { return }
        Task {
            if what.hasPrefix("result:") {
                result = try? await env.api.quiz(String(what.dropFirst(7)))
            } else if what == "start" {
                quiz = try? await env.api.startQuiz(course: course, count: 2, cards: 1, exercises: 1, minutes: 30)
            }
        }
        #endif
    }
}

/// A label and its value, in a card.
private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// How many of something, with − and +.
private struct CountRow: View {
    let title: String
    var detail: String?
    var unit: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Text(unit.map { "\(value) \($0)" } ?? "\(value)").font(.body.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 0) {
                button("minus", to: value - step).disabled(value <= range.lowerBound)
                Rectangle().fill(Theme.line).frame(width: 1, height: 18)
                button("plus", to: value + step).disabled(value >= range.upperBound)
            }
            .background(Theme.chip, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func button(_ symbol: String, to new: Int) -> some View {
        Button {
            withAnimation(.snappy) { value = min(max(new, range.lowerBound), range.upperBound) }
        } label: {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).frame(width: 40, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "More \(title.lowercased())" : "Fewer \(title.lowercased())")
    }
}

// MARK: Taking it

private struct PracticeTaking: View {
    let quiz: Quiz
    /// Each answer shown as it's checked; else all of them at the end.
    let revealNow: Bool
    let error: String?
    let check: (Int, QuizAnswer?) async throws -> QuizQuestion
    let finish: ([Int: QuizAnswer]) async -> Void
    let quit: () -> Void
    @State private var page = 0
    /// A multiple-choice question's letter, a flashcard's "right" or "wrong".
    @State private var answers: [Int: String] = [:]
    /// Open questions' answers, kept as they're written.
    @State private var drafts: [Int: OpenDraft] = [:]
    /// Questions checked while taking it, as they came back: with their key, or the course's solution.
    @State private var revealed: [Int: QuizQuestion] = [:]
    /// Flashcards turned over.
    @State private var turned: Set<Int> = []
    @State private var checking = false
    @State private var checkError: String?
    @State private var deadline: Date?
    @State private var finishing = false
    @State private var confirmFinish = false
    @State private var confirmQuit = false

    private var isLast: Bool { page == quiz.questions.count - 1 }
    private var current: QuizQuestion? { quiz.questions.indices.contains(page) ? quiz.questions[page] : nil }
    private var blanks: Int { quiz.questions.filter { !answered($0) }.count }
    private var uploading: Bool { drafts.values.contains { $0.uploading > 0 } }

    private func answered(_ question: QuizQuestion) -> Bool {
        if revealed[question.n] != nil { return true }
        return question.isOpen ? drafts[question.n]?.isEmpty == false : answers[question.n] != nil
    }

    /// What the answer is now, for checking it.
    private func answer(_ question: QuizQuestion) -> QuizAnswer? {
        if question.isOpen {
            guard let draft = drafts[question.n], !draft.isEmpty else { return nil }
            return .open(text: draft.text, photos: draft.photos.compactMap(\.id))
        }
        return answers[question.n].map(QuizAnswer.letter)
    }

    /// The question can be checked now: answered, not checked yet, and not a flashcard (it marks itself).
    private var canCheck: Bool {
        guard revealNow, let q = current, !q.isCard, revealed[q.n] == nil else { return false }
        return answer(q) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            TabView(selection: $page) {
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                    ScrollView {
                        pageView(question)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if let message = checkError ?? error {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 6)
            }
            controls
        }
        .pageGlow(Theme.study)
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
        .onChange(of: page) { checkError = nil }
        .task { await previewFill() }
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

    @ViewBuilder private func pageView(_ question: QuizQuestion) -> some View {
        if question.isCard {
            CardPage(question: question, turned: turned.contains(question.n), mark: answers[question.n]) {
                withAnimation(.snappy) { _ = turned.insert(question.n) }
            } judge: { verdict in
                withAnimation(.snappy) { answers[question.n] = answers[question.n] == verdict ? nil : verdict }
            }
        } else if question.isOpen {
            OpenQuestionPage(question: question, solution: revealed[question.n],
                             draft: Binding(get: { drafts[question.n] ?? OpenDraft() }, set: { drafts[question.n] = $0 }))
        } else {
            QuestionPage(question: question, chosen: answers[question.n], checked: revealed[question.n],
                         revealNow: revealNow) { letter in
                answers[question.n] = answers[question.n] == letter ? nil : letter
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 3) {
            ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                Capsule()
                    .fill(color(question))
                    .frame(height: index == page ? 6 : 4)
                    .onTapGesture { withAnimation { page = index } }
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    /// Checked: right in Professor's colour, wrong in orange; answered but not checked, half of it.
    private func color(_ question: QuizQuestion) -> Color {
        if let checked = revealed[question.n], !question.isOpen { return checked.correct == true ? Theme.study : .orange }
        if question.isCard, let mark = answers[question.n] { return mark == "right" ? Theme.study : .orange }
        return answered(question) ? Theme.study.opacity(0.5) : Theme.chip
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
                if canCheck {
                    Task { await checkCurrent() }
                } else if isLast {
                    confirmFinish = true
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                HStack {
                    if finishing || checking { ProgressView().tint(.white) }
                    Text(canCheck ? "Check" : isLast ? "Finish" : "Next").fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .frame(height: 48)
                .background(Theme.study, in: Capsule())
            }
            .buttonStyle(CardPress())
            .disabled(finishing || checking || (current.map { uploadingPhotos($0) } ?? false))
            Spacer()
            Button("Finish") { confirmFinish = true }
                .font(.subheadline)
                .frame(width: 60, height: 44)
                .opacity(isLast && !canCheck ? 0 : 1)
                .disabled(finishing || (isLast && !canCheck))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func uploadingPhotos(_ question: QuizQuestion) -> Bool {
        canCheck && question.isOpen && (drafts[question.n]?.uploading ?? 0) > 0
    }

    /// Hands in this one answer: it's final, and comes back with its key (or the course's solution).
    private func checkCurrent() async {
        guard let question = current else { return }
        checking = true
        defer { checking = false }
        do {
            let back = try await check(question.n, answer(question))
            withAnimation(.snappy) { revealed[question.n] = back }
            checkError = nil
        } catch {
            checkError = error.localizedDescription
        }
    }

    /// Simulator screenshots: `-previewFill YES` answers every question (and checks them, when answers show as
    /// they go), `-previewPage 2` opens that page, `-previewFinish YES` hands it in. These are real practice exams on
    /// the server: a handed-in one counts in the course's mastery and is posted in its chat, so delete it after.
    private func previewFill() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "previewFill") else { return }
        for question in quiz.questions {
            if question.isCard {
                turned.insert(question.n)
                answers[question.n] = question.n % 2 == 0 ? "right" : "wrong"
                continue
            }
            if question.isOpen {
                drafts[question.n] = OpenDraft(text: "The marginal product falls as capital grows, so growth slows.")
            } else {
                answers[question.n] = question.options.first?.letter
            }
            if revealNow, let back = try? await check(question.n, answer(question)) { revealed[question.n] = back }
        }
        page = min(defaults.integer(forKey: "previewPage"), quiz.questions.count - 1)
        if defaults.bool(forKey: "previewFinish") { submit() }
        #endif
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

/// Where a question comes from: the course's own material (its file and page), or written by Professor.
struct QuestionSource: View {
    let source: QuizSource?

    var body: some View {
        if let source {
            Label {
                Text(source.fromCourse ? ["From the course", source.name].compactMap { $0 }.joined(separator: " · ")
                     : "Written by Professor")
            } icon: {
                Image(systemName: source.fromCourse ? "checkmark.seal.fill" : "sparkles")
                    .foregroundStyle(Theme.study)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// The topic, where the question comes from, and on the right what it's worth.
private struct QuestionHeader: View {
    let question: QuizQuestion
    var trailing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(question.topic.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.study)
                Spacer()
                if let trailing { Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            QuestionSource(source: question.source)
        }
    }
}

private struct QuestionPage: View {
    let question: QuizQuestion
    let chosen: String?
    /// Came back from `check`: its key, whether it was right, why.
    let checked: QuizQuestion?
    let revealNow: Bool
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: question)
            Text(question.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            VStack(spacing: 10) {
                ForEach(question.options, id: \.letter) { option in
                    Button { choose(option.letter) } label: { OptionRow(option: option, state: state(option)) }
                        .buttonStyle(.plain)
                        .disabled(checked != nil)
                }
            }
            if let checked {
                Verdict(question: checked)
            } else {
                Text(chosen == nil ? "Leave it blank if you'd rather not guess."
                     : revealNow ? "Check it to see if it's right. Tap your answer again to leave it blank."
                     : "Tap your answer again to leave it blank.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func state(_ option: QuizOption) -> OptionRow.Mark {
        guard let checked else { return chosen == option.letter ? .chosen : .plain }
        if option.letter == checked.key { return .key }
        return option.letter == checked.answer ? .wrong : .plain
    }
}

/// A checked multiple-choice answer: right or not, and the explanation.
private struct Verdict: View {
    let question: QuizQuestion

    var body: some View {
        let right = question.correct == true, blank = question.answer == nil
        VStack(alignment: .leading, spacing: 8) {
            Label(right ? "Right" : blank ? "Left blank · the answer is \(question.key ?? "–")"
                  : "Not quite · the answer is \(question.key ?? "–")",
                  systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(right ? Theme.study : .orange)
            if let explanation = question.explanation, !explanation.isEmpty {
                Text(explanation.markdown).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// A flashcard: the front, then its back once turned, then Got it or Missed it (no penalty either way).
private struct CardPage: View {
    let question: QuizQuestion
    let turned: Bool
    let mark: String?
    let turn: () -> Void
    let judge: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: question, trailing: "Flashcard")
            VStack(alignment: .leading, spacing: 16) {
                Text(question.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
                if turned {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Text((question.key ?? "").markdown).font(.body).lineSpacing(3)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .card(padding: 20)
            if turned {
                HStack(spacing: 10) {
                    choice("Missed it", "xmark", "wrong", .orange)
                    choice("Got it", "checkmark", "right", Theme.study)
                }
                Text("Be honest: a missed card comes back sooner. No points are taken off.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button(action: turn) {
                    Label("Show the answer", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.study)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Theme.study.opacity(0.14), in: Capsule())
                }
                .buttonStyle(CardPress())
                Text("Say the answer to yourself first, then turn it.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(_ title: String, _ symbol: String, _ verdict: String, _ color: Color) -> some View {
        let on = mark == verdict
        return Button { judge(verdict) } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(on ? .white : color)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(on ? color : color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(CardPress())
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
    /// Checked while taking it: the course's solution, and the answer is final.
    let solution: QuizQuestion?
    @Binding var draft: OpenDraft
    @State private var camera = false
    @State private var library = false
    @FocusState private var writing: Bool

    private let most = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: question, trailing: question.points.map { $0 == 1 ? "1 point" : "\($0.points) points" })
            Text(question.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            TextEditor(text: $draft.text)
                .focused($writing)
                .frame(minHeight: solution == nil ? 180 : 80)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text(solution == nil ? "Your answer" : "No words, only photos")
                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(solution != nil)
            if !draft.photos.isEmpty { photoStrip }
            if let solution {
                VStack(alignment: .leading, spacing: 8) {
                    Label("The course's solution", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.study)
                    Text((solution.modelAnswer ?? "").markdown).font(.subheadline).lineSpacing(2)
                    Text("Professor marks your answer when you finish.").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                HStack(spacing: 8) {
                    if CameraPicker.isAvailable {
                        Chip(title: "Camera", systemImage: "camera") { writing = false; camera = true }
                    }
                    Chip(title: "Photos", systemImage: "photo.on.rectangle") { writing = false; library = true }
                    Spacer()
                }
                .disabled(draft.photos.count >= most)
                Text("Write it here, or work on paper and photograph it: Professor reads both.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                            if solution == nil {
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
            if state == .key { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.study) }
            if state == .wrong { Image(systemName: "xmark").fontWeight(.semibold).foregroundStyle(.orange) }
        }
        .padding(14)
        .background(state == .plain ? Theme.row : badge.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(state == .plain ? Theme.line : badge, lineWidth: state == .plain ? 1 : 1.5)
        }
        .contentShape(Rectangle())
    }

    private var badge: Color {
        switch state {
        case .plain: Theme.chip
        case .chosen, .key: Theme.study
        case .wrong: .orange
        }
    }
}

// MARK: Results

private struct PracticeResults: View {
    let quiz: Quiz
    /// Opened from the result's card in the course chat: no pointer back to it.
    var fromChat = false
    /// Another practice exam, back on the setup page.
    var again: (() -> Void)?
    @State private var onlyMissed = true

    private var missed: [QuizQuestion] { quiz.questions.filter { $0.correct != true } }
    private var shown: [QuizQuestion] { onlyMissed ? missed : quiz.questions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let score = quiz.score {
                    header(score)
                    if let topics = score.topics, topics.count > 1 { byTopic(topics) }
                }
                HStack {
                    Text("Answers").font(.title3.weight(.bold))
                    Spacer()
                    Picker("Show", selection: $onlyMissed) {
                        Text("Missed · \(missed.count)").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
                if shown.isEmpty {
                    Label("Nothing missed", systemImage: "star.fill").foregroundStyle(Theme.study)
                        .frame(maxWidth: .infinity).card()
                }
                ForEach(shown) { ReviewCard(question: $0, grading: quiz.score?.grading == true).card() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .pageGlow(Theme.study)
        .navigationTitle(quiz.title ?? "Result")
    }

    /// Of the most the paper scores, 0–100 (wrong answers can take points below 0).
    private func percent(_ score: QuizScore) -> Int {
        score.max > 0 ? Int((min(max(score.points / score.max, 0), 1) * 100).rounded()) : 0
    }

    private func header(_ score: QuizScore) -> some View {
        VStack(spacing: 14) {
            ScoreRing(score: percent(score), tint: Theme.study, size: 108)
            Text("\(score.points.points) / \(score.max.points)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(score.right) right · \(score.wrong) wrong · \(score.blank) blank")
                .font(.subheadline).foregroundStyle(.secondary)
            if score.grading == true {
                Label {
                    Text("Professor is marking the open answers; they count as 0 until then.")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !fromChat {
                Text("Professor has the result in the course's chat.").font(.footnote).foregroundStyle(.secondary)
            }
            if let again {
                Button(action: again) {
                    Label("New practice exam", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Theme.study, in: Capsule())
                }
                .buttonStyle(CardPress())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
        .padding(.top, 8)
    }

    private func byTopic(_ topics: [QuizTopicScore]) -> some View {
        DetailCard("By topic") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(topics) { topic in
                    let share = Double(topic.right) / Double(max(1, topic.total))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(topic.title).font(.subheadline)
                            Spacer()
                            Text("\(topic.right) of \(topic.total)").font(.subheadline).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Capsule().fill(Theme.chip)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(share < 0.5 ? Color.orange : Theme.study)
                                        .frame(width: max(6, g.size.width * share))
                                }
                            }
                            .frame(height: 6)
                    }
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
                Text("\(question.n). \(question.topic.title)").font(.caption.weight(.semibold)).foregroundStyle(Theme.study)
                Spacer()
                if question.isOpen {
                    marks
                } else if question.isCard {
                    cardMark
                } else if question.answer == nil {
                    Text("Blank").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            QuestionSource(source: question.source)
            Text(question.text.markdown).font(.body.weight(.medium))
            if question.isOpen { open } else if question.isCard { back } else { choice }
        }
    }

    @ViewBuilder private var cardMark: some View {
        switch question.answer {
        case "right": Text("Got it").font(.caption.weight(.semibold)).foregroundStyle(Theme.study)
        case "wrong": Text("Missed it").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        default: Text("Not marked").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var back: some View {
        if let key = question.key, !key.isEmpty {
            Text(key.markdown).font(.subheadline).lineSpacing(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder private var marks: some View {
        let points = question.points ?? 0
        if question.response == nil {
            Text("Blank · 0 / \(points.points)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        } else if let awarded = question.awarded {
            Text("\(awarded.points) / \(points.points)").font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(question.correct == true ? Theme.study : .orange)
        } else if grading {
            Label("Marking…", systemImage: "hourglass").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } else {
            Text("Not marked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if let feedback = question.feedback, !feedback.isEmpty {
            Text(feedback.markdown).font(.subheadline).lineSpacing(2)
        }
        if let answer = question.modelAnswer, !answer.isEmpty {
            DisclosureGroup(question.source?.fromCourse == true ? "The course's solution" : "Model answer") {
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
            .tint(Theme.study)
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
