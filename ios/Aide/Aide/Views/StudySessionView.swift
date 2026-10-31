import SwiftUI

/// The Study page (docs/API.md, "Practice exams", study sessions): a course's notebook gone over Quizlet's way.
/// Flashcards turned and marked by you, multiple choice shown right or wrong at once, answers written in your own
/// words and marked by the model in a couple of seconds ("I was right" when it's wrong about you). In rounds: what you
/// missed comes back until you know it all. No timer, no score, nothing posted; every answer counts for how well
/// each topic is known.
struct StudySessionView: View {
    let course: Int
    var courseName: String?
    /// Topics to start on, by title or id (a review session's, a topic page's).
    var focus: [String] = []
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var bank: QuizBank?
    @State private var error: String?
    @State private var mode: StudyMode = .flashcards
    @State private var scope: Scope = .all
    @State private var picked: Set<String> = []
    /// 0 for all of them.
    @State private var size = 20
    @State private var starting = false
    @State private var quiz: Quiz?

    enum Scope: Hashable { case all, weakest, picked }

    var body: some View {
        NavigationStack {
            Group {
                if let quiz {
                    StudyRunView(quiz: quiz, again: { withAnimation { self.quiz = nil } }, close: { dismiss() })
                        .id(quiz.id)
                } else {
                    setup
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.study)
    }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TopBlock("Study", overline: courseName) {
                    Text("No timer and no score. Whatever you miss comes back until you know it.")
                        .foregroundStyle(.secondary)
                }
                if let error { ErrorCard(text: error) }
                if let bank {
                    if bank.questions + bank.cards + bank.exercises == 0 {
                        Text("Nothing to study yet. Flashcards and questions come with the notebook's topic pages.")
                            .foregroundStyle(.secondary).card()
                    } else {
                        modes
                        topicsCard(bank)
                        sizeCard
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
            if bank != nil, available.total > 0 {
                Button { Task { await start() } } label: {
                    HStack(spacing: 8) {
                        if starting { ProgressView().tint(.white) }
                        Text(startTitle)
                    }
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Theme.study, in: Capsule())
                }
                .buttonStyle(CardPress())
                .disabled(starting || mode.count(available) == 0)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task { await load() }
    }

    private var modes: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(StudyMode.allCases) { m in
                let count = m.count(available), on = m == mode
                Button { withAnimation(.snappy) { mode = m } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: m.symbol).font(.title2)
                            .foregroundStyle(on ? .white : Theme.study)
                            .frame(height: 30)
                        Text(m.title).font(.headline)
                        Text(m.detail).font(.footnote).foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(m.amount(count)).font(.caption.weight(.semibold))
                            .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                    }
                    .foregroundStyle(on ? .white : .primary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .padding(14)
                    .background(on ? Theme.study : Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(CardPress())
                .disabled(count == 0)
                .opacity(count == 0 ? 0.45 : 1)
            }
        }
    }

    private func topicsCard(_ bank: QuizBank) -> some View {
        DetailCard("Topics", padding: 0) {
            HStack(spacing: 8) {
                choice("All", .all)
                if !weakest.isEmpty { choice("Weakest \(weakest.count)", .weakest) }
                choice("Choose", .picked)
                Spacer(minLength: 0)
            }
            .padding(12)
            if scope == .weakest || scope == .picked {
                ForEach(scope == .weakest ? bank.topics.filter { weakest.contains($0.id) } : bank.topics) { topic in
                    RowDivider(leading: 16)
                    Button {
                        guard scope == .picked else { return }
                        if picked.contains(topic.id) { picked.remove(topic.id) } else { picked.insert(topic.id) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title).foregroundStyle(.primary)
                                Text(standing(topic)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if scope == .picked {
                                Image(systemName: picked.contains(topic.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(picked.contains(topic.id) ? Theme.study : Color.secondary.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                }
            }
        }
    }

    private func choice(_ title: String, _ value: Scope) -> some View {
        Chip(title: title, style: scope == value ? .prominent : .plain, tint: Theme.study) {
            withAnimation(.snappy) { scope = value }
        }
    }

    private var sizeCard: some View {
        DetailCard("How many") {
            HStack(spacing: 8) {
                ForEach([10, 20, 0], id: \.self) { n in
                    Chip(title: n == 0 ? "All" : "\(n)", style: size == n ? .prominent : .plain, tint: Theme.study) {
                        size = n
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "4 to learn · 2 new" or "All known".
    private func standing(_ topic: QuizBankTopic) -> String {
        let parts = [(topic.learning ?? 0, "to learn"), (topic.unseen ?? 0, "new")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "All known" : parts.joined(separator: " · ")
    }

    /// The three topics with the most missed, then the most never seen.
    private var weakest: [String] {
        (bank?.topics ?? [])
            .filter { ($0.learning ?? 0) + ($0.unseen ?? 0) > 0 }
            .sorted { (($0.learning ?? 0), ($0.unseen ?? 0)) > (($1.learning ?? 0), ($1.unseen ?? 0)) }
            .prefix(3).map(\.id)
    }

    /// The topics asked about; nil for all.
    private var chosen: [String]? {
        switch scope {
        case .all: nil
        case .weakest: weakest
        case .picked: Array(picked)
        }
    }

    private var available: StudyMode.Available {
        let topics = (bank?.topics ?? []).filter { chosen?.contains($0.id) ?? true }
        return .init(questions: topics.reduce(0) { $0 + $1.questions },
                     cards: topics.reduce(0) { $0 + ($1.cards ?? 0) },
                     exercises: topics.reduce(0) { $0 + ($1.exercises ?? 0) })
    }

    private var startTitle: String {
        let n = mode.count(available), take = size == 0 ? n : min(size, n)
        return take == 1 ? "Start · 1" : "Start · \(take)"
    }

    private func load() async {
        guard bank == nil else { return }
        do {
            let fresh = try await env.api.quizBank(course: course)
            if !focus.isEmpty {
                let wanted = Set(focus.map { $0.lowercased() })
                picked = Set(fresh.topics.filter { wanted.contains($0.id.lowercased()) || wanted.contains($0.title.lowercased()) }.map(\.id))
                if !picked.isEmpty { scope = .picked }
            }
            bank = fresh
            if mode.count(available) == 0, let first = StudyMode.allCases.first(where: { $0.count(available) > 0 }) {
                mode = first
            }
            error = nil
            // Simulator screenshots: `-previewStudy write` starts 10 of that mode.
            if env.settings.isPreview, let name = UserDefaults.standard.string(forKey: "previewStudy"),
               let preview = StudyMode(rawValue: name) {
                mode = preview
                size = 10
                await start()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        let n = size == 0 ? 60 : size
        var count = 0, cards = 0, write = 0, exercises = 0
        switch mode {
        case .flashcards: cards = n
        case .learn: count = n
        case .write:
            exercises = min(available.exercises, n / 3)
            write = n - exercises
        case .mix:
            count = n / 3; cards = n / 3; write = n - 2 * (n / 3)
        }
        do {
            let started = try await env.api.startStudy(course: course, count: count, cards: cards, write: write,
                                                       exercises: exercises, topics: chosen)
            withAnimation { quiz = started }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum StudyMode: String, CaseIterable, Identifiable {
    case flashcards, learn, write, mix

    struct Available { var questions = 0, cards = 0, exercises = 0; var total: Int { questions + cards + exercises } }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .flashcards: "Flashcards"
        case .learn: "Learn"
        case .write: "Write"
        case .mix: "Mix"
        }
    }
    var symbol: String {
        switch self {
        case .flashcards: "rectangle.on.rectangle.angled"
        case .learn: "checklist"
        case .write: "pencil.line"
        case .mix: "shuffle"
        }
    }
    var detail: String {
        switch self {
        case .flashcards: "Turn them, say if you knew it."
        case .learn: "Multiple choice, right or wrong at once."
        case .write: "Answer in your words, marked in seconds."
        case .mix: "All three, shuffled."
        }
    }
    func count(_ a: Available) -> Int {
        switch self {
        case .flashcards: a.cards
        case .learn: a.questions
        case .write: a.cards + a.exercises
        case .mix: a.total
        }
    }
    func amount(_ n: Int) -> String {
        switch self {
        case .flashcards: n == 1 ? "1 card" : "\(n) cards"
        default: n == 1 ? "1 question" : "\(n) questions"
        }
    }
}

// MARK: The session

/// A study session in rounds: each question once, then the missed ones again, until they're all known.
private struct StudyRunView: View {
    let quiz: Quiz
    let again: () -> Void
    let close: () -> Void
    @EnvironmentObject private var env: AppEnvironment

    enum Phase { case asking, roundDone, done }
    @State private var phase = Phase.asking
    @State private var round = 1
    @State private var queue: [Int] = []
    @State private var index = 0
    @State private var missed: [Int] = []
    @State private var known: Set<Int> = []
    /// Right the first time it was asked, or not.
    @State private var first: [Int: Bool] = [:]
    @State private var finished = false

    // The question on screen.
    @State private var turned = false
    @State private var drag: CGSize = .zero
    @State private var result: QuizQuestion?
    @State private var draft = OpenDraft()
    @State private var busy = false
    /// The model couldn't mark it: the answer is kept, and you say whether it was right.
    @State private var selfMark = false
    @State private var error: String?

    private var current: QuizQuestion? {
        guard phase == .asking, index < queue.count else { return nil }
        return quiz.questions.first { $0.n == queue[index] }
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch phase {
                    case .asking:
                        if let q = current {
                            Group {
                                if q.isCard {
                                    flashcard(q)
                                } else if q.isOpen {
                                    written(q)
                                } else {
                                    learn(q)
                                }
                            }
                            .id("\(round)-\(index)")
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                        }
                    case .roundDone: roundDone
                    case .done: done
                    }
                    if let error { ErrorCard(text: error) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .pageGlow(Theme.study)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { close() }
            }
            ToolbarItem(placement: .principal) {
                Text(phase == .done ? "Done" : "Round \(round)").font(.subheadline.weight(.semibold))
            }
        }
        .bottomBar { bottom }
        .sensoryFeedback(trigger: result) { _, new in
            guard let new else { return nil }
            return isKnown(new) ? .success : .error
        }
        .onAppear { if queue.isEmpty { queue = quiz.questions.map(\.n) } }
        .onDisappear { finish() }
    }

    private var progress: some View {
        let total = max(quiz.questions.count, 1)
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(known.count), total: Double(total)).tint(Theme.study)
            HStack {
                Text("\(known.count) known")
                Spacer()
                Text(quiz.questions.count - known.count == 0 ? "All done" : "\(quiz.questions.count - known.count) to go")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        .animation(.snappy, value: known.count)
    }

    // MARK: Flashcards

    private func flashcard(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: q, trailing: "Flashcard")
            Turn(angle: turned ? 180 : 0,
                 front: face(q.text, label: "Tap to turn", big: true),
                 back: face(q.key ?? "", label: "Answer", big: false))
                .overlay { swipeHint }
                .offset(x: drag.width, y: drag.height * 0.15)
                .rotationEffect(.degrees(Double(drag.width) / 22))
                .onTapGesture { withAnimation(.spring(duration: 0.45)) { turned.toggle() } }
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            if abs(value.translation.width) > 110 {
                                judge(q, knew: value.translation.width > 0)
                            } else {
                                withAnimation(.spring) { drag = .zero }
                            }
                        }
                )
            Text("Say it to yourself, tap to turn. Swipe right if you knew it, left if not.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func face(_ text: String, label: String, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(Theme.study)
            Spacer(minLength: 0)
            Text(text.markdown).font(big ? .title2.weight(.semibold) : .body).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: big ? .center : .leading)
                .multilineTextAlignment(big ? .center : .leading)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line) }
    }

    @ViewBuilder private var swipeHint: some View {
        let w = drag.width
        if abs(w) > 30 {
            let knew = w > 0, color: Color = knew ? Theme.study : .orange
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(color, lineWidth: 3)
                .overlay(alignment: knew ? .topLeading : .topTrailing) {
                    Text(knew ? "Know" : "Still learning")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(color, in: Capsule())
                        .padding(14)
                }
                .opacity(min(1, (abs(w) - 30) / 80))
                .allowsHitTesting(false)
        }
    }

    private func judge(_ q: QuizQuestion, knew: Bool) {
        let id = quiz.id
        Task { _ = try? await env.api.checkQuiz(id, n: q.n, answer: .letter(knew ? "right" : "wrong")) }
        withAnimation(.easeIn(duration: 0.2)) { drag = CGSize(width: knew ? 600 : -600, height: 0) }
        record(q.n, knew)
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            advance()
        }
    }

    // MARK: Learn (multiple choice)

    private func learn(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: q)
            Text(q.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            VStack(spacing: 10) {
                ForEach(q.options, id: \.letter) { option in
                    Button { Task { await choose(q, option.letter) } } label: {
                        OptionRow(option: option, state: state(option))
                    }
                    .buttonStyle(.plain)
                    .disabled(result != nil || busy)
                }
            }
            if let result {
                Verdict(question: result)
            }
        }
    }

    private func state(_ option: QuizOption) -> OptionRow.Mark {
        guard let result else { return .plain }
        if option.letter == result.key { return .key }
        return option.letter == result.answer ? .wrong : .plain
    }

    private func choose(_ q: QuizQuestion, _ letter: String) async {
        busy = true
        defer { busy = false }
        do {
            let checked = try await env.api.checkQuiz(quiz.id, n: q.n, answer: .letter(letter))
            withAnimation(.snappy) { result = checked }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Write (open, marked by the model)

    private func written(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionHeader(question: q, trailing: q.source?.fromCourse == true ? "Exercise" : "Write")
            Text(q.text.markdown).font(.title3.weight(.medium)).lineSpacing(3)
            WriteBox(draft: $draft, photos: q.source?.fromCourse == true, locked: result != nil || busy || selfMark)
            if busy {
                HStack(spacing: 10) { ProgressView(); Text("Marking…").foregroundStyle(.secondary) }.card()
            }
            if let result {
                if selfMark {
                    selfMarkCard(result)
                } else {
                    mark(result)
                }
            }
        }
    }

    private func mark(_ q: QuizQuestion) -> some View {
        let full = q.points ?? 1, got = q.awarded ?? 0
        let right = got >= full, partly = !right && got > 0
        let color: Color = right ? Theme.study : partly ? .yellow : .orange
        return VStack(alignment: .leading, spacing: 12) {
            Label(right ? "Right" : partly ? "Partly right" : "Not quite",
                  systemImage: right ? "checkmark.circle.fill" : partly ? "circle.lefthalf.filled" : "xmark.circle.fill")
                .font(.headline).foregroundStyle(color)
            if let feedback = q.feedback, !feedback.isEmpty {
                Text(feedback.markdown).font(.subheadline).lineSpacing(2)
            }
            answerBlock(q)
            if !right {
                Button { Task { await override(q, correct: true) } } label: {
                    Label("I was right", systemImage: "hand.thumbsup")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.study)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.study.opacity(0.14), in: Capsule())
                }
                .buttonStyle(CardPress())
                .disabled(busy)
            }
        }
        .card()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func selfMarkCard(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't mark it just now. Compare it with the answer and say how it went.")
                .font(.subheadline).foregroundStyle(.secondary)
            answerBlock(q)
            HStack(spacing: 10) {
                pill("Missed it", "xmark", .orange) { Task { await override(q, correct: false) } }
                pill("Got it", "checkmark", Theme.study) { Task { await override(q, correct: true) } }
            }
        }
        .card()
    }

    @ViewBuilder private func answerBlock(_ q: QuizQuestion) -> some View {
        if let answer = q.modelAnswer, !answer.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(q.source?.fromCourse == true ? "THE COURSE'S SOLUTION" : "THE ANSWER")
                    .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                Text(answer.markdown).font(.subheadline).lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func pill(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold)).foregroundStyle(color)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(CardPress())
        .disabled(busy)
    }

    private func submit(_ q: QuizQuestion) async {
        busy = true
        defer { busy = false }
        let answer = QuizAnswer.open(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     photos: draft.photos.compactMap(\.id))
        do {
            let marked = try await env.api.checkQuiz(quiz.id, n: q.n, answer: answer)
            withAnimation(.snappy) { result = marked }
            error = nil
        } catch {
            // Not marked (the model failed): the answer is kept; show the answer and let the user say.
            if let kept = (try? await env.api.quiz(quiz.id))?.questions.first(where: { $0.n == q.n }), kept.response != nil {
                withAnimation(.snappy) { selfMark = true; result = kept }
                self.error = nil
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func override(_ q: QuizQuestion, correct: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let marked = try await env.api.markQuiz(quiz.id, n: q.n, correct: correct)
            withAnimation(.snappy) { result = marked }
            if selfMark { selfMark = false; next() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Rounds

    private func isKnown(_ q: QuizQuestion) -> Bool {
        q.isOpen ? (q.awarded ?? 0) >= (q.points ?? 1) : q.correct == true
    }

    private func record(_ n: Int, _ knew: Bool) {
        if first[n] == nil { first[n] = knew }
        if knew { known.insert(n) } else { missed.append(n) }
    }

    /// Continue: what was shown counts, then the next question.
    private func next() {
        guard let q = current, let result else { return }
        record(q.n, isKnown(result))
        advance()
    }

    private func advance() {
        withAnimation(.snappy) {
            turned = false
            drag = .zero
            result = nil
            draft = OpenDraft()
            selfMark = false
            error = nil
            index += 1
            if index >= queue.count { phase = missed.isEmpty ? .done : .roundDone }
        }
        if phase == .done { finish() }
    }

    private func nextRound() {
        withAnimation(.snappy) {
            queue = missed.shuffled()
            missed = []
            index = 0
            round += 1
            phase = .asking
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let id = quiz.id
        Task { _ = try? await env.api.finishQuiz(id, answers: [:]) }
    }

    @ViewBuilder private var bottom: some View {
        if let q = current, !q.isCard {
            Group {
                if result != nil, !selfMark {
                    big("Continue", filled: true) { next() }
                } else if q.isOpen, result == nil {
                    big(busy ? "Marking…" : "Check", filled: true) { Task { await submit(q) } }
                        .disabled(busy || draft.isEmpty || draft.uploading > 0)
                        .opacity(draft.isEmpty && !busy ? 0.45 : 1)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        } else if let q = current, q.isCard {
            HStack(spacing: 10) {
                pill("Still learning", "arrow.uturn.left", .orange) { judge(q, knew: false) }
                pill("Know", "checkmark", Theme.study) { judge(q, knew: true) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func big(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold)).foregroundStyle(filled ? .white : Theme.study)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(filled ? Theme.study : Theme.study.opacity(0.14), in: Capsule())
        }
        .buttonStyle(CardPress())
    }

    private var roundDone: some View {
        let toGo = missed.count, total = queue.count
        return VStack(alignment: .leading, spacing: 16) {
            TopBlock("Round \(round) done") {
                Text("You knew \(total - toGo) of \(total). \(toGo == 1 ? "1 comes" : "\(toGo) come") back now, until you know them.")
                    .foregroundStyle(.secondary)
            }
            missedTopics(missed)
            big("Go over the \(toGo) missed", filled: true) { nextRound() }
            big("Stop here", filled: false) { finish(); close() }
        }
    }

    private var done: some View {
        let total = quiz.questions.count, right = first.values.filter { $0 }.count
        let firstMissed = first.filter { !$0.value }.map(\.key)
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Theme.study)
                .padding(.top, 20)
            TopBlock(total == 1 ? "You know it" : "You know all \(total)") {
                Text(right == total ? "Every one right the first time."
                     : "\(right) of \(total) right the first time, the rest in \(round == 2 ? "one more round" : "\(round - 1) more rounds").")
                    .foregroundStyle(.secondary)
            }
            if !firstMissed.isEmpty {
                missedTopics(firstMissed, title: "Missed at first")
            }
            big("Study again", filled: true) { again() }
            big("Done", filled: false) { close() }
        }
    }

    /// The topics the missed ones are on, with how many.
    @ViewBuilder private func missedTopics(_ ns: [Int], title: String = "To go over") -> some View {
        let byTopic = Dictionary(grouping: quiz.questions.filter { ns.contains($0.n) }, by: \.topic.title)
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        if !byTopic.isEmpty {
            DetailCard(title, padding: 0) {
                ForEach(Array(byTopic.enumerated()), id: \.offset) { i, item in
                    if i > 0 { RowDivider(leading: 16) }
                    HStack {
                        Text(item.0)
                        Spacer()
                        Text("\(item.1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
        }
    }
}

/// A card turning over: the front until it's half way, then the back (drawn the right way round).
private struct Turn<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                front
            } else {
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
    }
}

/// The answer as it's written: words, and for the course's exercises photos of the work on paper.
private struct WriteBox: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var draft: OpenDraft
    let photos: Bool
    let locked: Bool
    @State private var camera = false
    @State private var library = false
    @FocusState private var writing: Bool

    private let most = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft.text)
                .focused($writing)
                .frame(minHeight: locked ? 60 : 140)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text(photos ? "Your answer, or photos of your work" : "Your answer, in your own words")
                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(locked)
                .onAppear { if !photos { writing = true } }
            if !draft.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.photos, id: \.key) { photo in
                            ServerPhoto(id: photo.id, local: photo.jpeg)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    if photo.id == nil, !photo.failed {
                                        ProgressView().tint(.white).padding(6).background(.black.opacity(0.4), in: Circle())
                                    }
                                }
                        }
                    }
                }
            }
            if photos, !locked {
                HStack(spacing: 8) {
                    if CameraPicker.isAvailable {
                        Chip(title: "Camera", systemImage: "camera") { writing = false; camera = true }
                    }
                    Chip(title: "Photos", systemImage: "photo.on.rectangle") { writing = false; library = true }
                    Spacer()
                }
                .disabled(draft.photos.count >= most)
            }
        }
        .photoSources(camera: $camera, library: $library, limit: most - draft.photos.count) { picked in
            for photo in picked.prefix(most - draft.photos.count) { add(photo) }
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
