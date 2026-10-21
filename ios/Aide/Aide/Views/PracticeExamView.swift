import SwiftUI

/// A practice exam from a course's notebook (docs/API.md, "Practice exams"): how many questions and whether it's
/// timed, then a question a page, then the score the exam would give and every explanation. Professor posts the
/// result in the course's chat.
struct PracticeExamView: View {
    let course: Int
    var courseName: String?
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
            if let bank {
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
        .navigationTitle(courseName.map { "Practice · \($0)" } ?? "Practice exam")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await load() }
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
            quiz = try await env.api.startQuiz(course: course, count: count, minutes: timed ? minutes : nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(_ answers: [Int: String]) async {
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
    let finish: ([Int: String]) async -> Void
    let quit: () -> Void
    @State private var page = 0
    @State private var answers: [Int: String] = [:]
    @State private var deadline: Date?
    @State private var finishing = false
    @State private var confirmFinish = false
    @State private var confirmQuit = false

    private var isLast: Bool { page == quiz.questions.count - 1 }
    private var blanks: Int { quiz.questions.count - answers.count }

    var body: some View {
        VStack(spacing: 0) {
            progress
            TabView(selection: $page) {
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                    ScrollView {
                        QuestionPage(question: question, chosen: answers[question.n]) { letter in
                            answers[question.n] = answers[question.n] == letter ? nil : letter
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
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
        .confirmationDialog("Finish the practice exam?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish") { submit() }
        } message: {
            Text(blanks == 0 ? "Every question has an answer."
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
                    .fill(answers[question.n] != nil ? Theme.accent : Theme.chip)
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
        Task {
            await finish(answers)
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
                ForEach(shown) { ReviewCard(question: $0) }
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
            Text("Professor has the result in the course's chat.").font(.footnote).foregroundStyle(.secondary)
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

private struct ReviewCard: View {
    let question: QuizQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(question.n). \(question.topic.title)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if question.answer == nil {
                    Text("Blank").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text(question.text.markdown).font(.body.weight(.medium))
            ForEach(question.options, id: \.letter) { option in
                OptionRow(option: option, state: option.letter == question.key ? .key
                          : option.letter == question.answer ? .wrong : .plain)
            }
            if let explanation = question.explanation, !explanation.isEmpty {
                Text(explanation.markdown).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
            }
        }
        .padding(.bottom, 8)
    }
}

private extension Double {
    /// 22.75, 30: no trailing zeros.
    var points: String { formatted(.number.precision(.fractionLength(0...2))) }
}
