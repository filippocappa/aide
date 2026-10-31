import AVFoundation
import NaturalLanguage
import SwiftUI

/// A lesson (docs/API.md, "Lessons"): a topic taught a step at a time, Brilliant's way. The hook and goals, then each
/// step: read it (or listen), say whether you got it (Not quite tells it another way), answer a check, and on; Ask
/// Professor about any step. At the end you explain the topic back in your own words and Professor says what stuck.
/// Professor writes the lesson the first time it's opened (a minute or so), on the Claude plan when it's on.
struct LessonView: View {
    let course: Int
    var courseName: String?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var topic: LessonTopicRef
    @State private var lesson: Lesson?
    @State private var error: String?
    @State private var practising: StudyTarget?

    init(topic: LessonTopicRef, course: Int, courseName: String? = nil) {
        self.course = course
        self.courseName = courseName
        _topic = State(initialValue: topic)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let lesson, lesson.ready {
                    LessonRun(lesson: lesson, courseName: courseName,
                              next: { ref in withAnimation { self.lesson = nil; topic = ref } },
                              rewrite: { Task { await open(again: true) } },
                              restart: { Task { await open(restart: true) } },
                              practise: { practising = StudyTarget(course: course, name: courseName, topics: [topic.id]) },
                              close: { dismiss() })
                        .id(lesson.id + (lesson.startedAt ?? "new"))
                } else {
                    waiting
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.study)
        .task(id: topic.id) { await open() }
        .task(id: lesson?.building == true) {
            // While Professor writes it, follow it.
            while !Task.isCancelled, lesson?.building == true {
                try? await Task.sleep(for: .seconds(3))
                if let fresh = try? await env.api.lesson(topic: topic.id) { withAnimation { lesson = fresh } }
            }
        }
        .fullScreenCover(item: $practising) { target in
            StudySessionView(course: target.course, courseName: target.name, focus: target.topics)
        }
    }

    private var waiting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TopBlock(topic.title, overline: courseName)
                if let lesson, lesson.status == "failed" {
                    ErrorCard(text: "Professor couldn't write this lesson. \(lesson.error ?? "")")
                    Chip(title: "Try again", systemImage: "arrow.clockwise", style: .prominent, tint: Theme.study) {
                        Task { await open() }
                    }
                } else if let error {
                    ErrorCard(text: error)
                    Chip(title: "Try again", systemImage: "arrow.clockwise") { Task { await open() } }
                } else if lesson?.building == true {
                    building
                } else {
                    ProgressView().frame(maxWidth: .infinity).card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .pageGlow(Theme.study)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
    }

    private var building: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                Text("Professor is turning the notes into a lesson").font(.headline)
            }
            Text("Short steps to read, each with a question to check you've got it. It takes a minute or so the first time, then it's kept.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let until = lesson?.waiting.flatMap(Wire.parse) {
                Label("The Claude plan is at its limit: it goes on around \(until.formatted(date: .omitted, time: .shortened)), or in the course chat you can finish it on OpenRouter.",
                      systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private func open(again: Bool = false, restart: Bool = false) async {
        if again { withAnimation { lesson = nil } }
        do {
            let fresh = try await env.api.startLesson(topic: topic.id, again: again, restart: restart)
            withAnimation { lesson = fresh }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension LessonTopicRef: Identifiable {}

// MARK: Going through it

private struct LessonRun: View {
    @State var lesson: Lesson
    var courseName: String?
    let next: (LessonTopicRef) -> Void
    let rewrite: () -> Void
    let restart: () -> Void
    let practise: () -> Void
    let close: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var voice = LessonVoice()

    enum Phase: Hashable { case intro, step(Int), explain, result }
    @State private var phase = Phase.intro

    // The step on screen.
    @State private var gotIt = false
    @State private var anotherWay = false
    @State private var checkIndex = 0
    @State private var result: LessonCheckResult?
    @State private var written = ""
    @State private var busy = false
    @State private var asks: [LessonQA] = []
    @State private var asking = false
    @State private var question = ""
    @State private var error: String?
    @FocusState private var typing: Bool

    // The end.
    @State private var explanation = ""

    private var steps: [LessonStep] { lesson.steps }

    var body: some View {
        VStack(spacing: 0) {
            if case .step(let i) = phase { bar(i) }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 0).id("top")
                        switch phase {
                        case .intro: intro
                        case .step(let i): step(steps[i])
                        case .explain: explain
                        case .result: outcome
                        }
                        if let error { ErrorCard(text: error) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .pageColumn()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: phase) { scroll.scrollTo("top", anchor: .top) }
                .onChange(of: gotIt) { if gotIt { later { scroll.scrollTo("end", anchor: .bottom) } } }
                .onChange(of: anotherWay) { if anotherWay { later { scroll.scrollTo("again", anchor: .top) } } }
                .onChange(of: result) { if result != nil { later { scroll.scrollTo("end", anchor: .bottom) } } }
                .onChange(of: checkIndex) { later { scroll.scrollTo("check", anchor: .top) } }
                .onChange(of: asks.count) { later { scroll.scrollTo("end", anchor: .bottom) } }
            }
        }
        .pageGlow(Theme.study)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { voice.stop(); close() }
            }
            ToolbarItem(placement: .principal) {
                Text(lesson.topic.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
        }
        .bottomBar { bottom.padding(.horizontal, 16).padding(.vertical, 8) }
        .sensoryFeedback(trigger: result) { _, new in
            guard let correct = new?.correct else { return nil }
            return correct ? .success : .error
        }
        .onDisappear { voice.stop() }
    }

    private func later(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.snappy) { action() } }
    }

    /// The steps as segments: done, this one, to come.
    private func bar(_ i: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { n in
                Capsule().fill(n < i ? Theme.study : n == i ? Theme.study.opacity(0.5) : Theme.chip)
                    .frame(height: 5)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
        .animation(.snappy, value: i)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            TopBlock(lesson.topic.title, overline: courseName) {
                Text("\(steps.count) steps · about \(max(3, steps.count * 2)) min")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.study)
            }
            if let hook = lesson.hook, !hook.isEmpty {
                NoteText(markdown: hook).font(.title3)
            }
            if !lesson.goals.isEmpty {
                DetailCard("By the end") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lesson.goals, id: \.self) { goal in
                            Label { MathText.text(goal) } icon: {
                                Image(systemName: "target").foregroundStyle(Theme.study)
                            }
                        }
                    }
                }
            }
            if lesson.stale == true {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The notes changed since this lesson was written.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                    Chip(title: "Write it again", systemImage: "sparkles") { rewrite() }
                }
                .card()
            }
            if let explained = lesson.explained, lesson.finished {
                Button { withAnimation(.snappy) { phase = .result } } label: {
                    HStack {
                        VerdictBadge(verdict: explained.verdict)
                        Text("How it went last time").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .card()
                }
                .buttonStyle(CardPress())
            }
        }
    }

    // MARK: A step

    private func step(_ s: LessonStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STEP \(s.n) OF \(steps.count)").font(.caption.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(Theme.study)
                    Text(s.title).font(.title2.bold())
                }
                Spacer()
                Button { voice.toggle(s.say ?? s.body) } label: {
                    Image(systemName: voice.speaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.study)
                        .frame(width: 40, height: 40)
                        .background(Theme.study.opacity(0.14), in: Circle())
                }
                .buttonStyle(CardPress())
                .accessibilityLabel(voice.speaking ? "Stop reading" : "Read it to me")
            }
            NoteText(markdown: s.body)
            if anotherWay {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ANOTHER WAY TO SEE IT").font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(Theme.study)
                    NoteText(markdown: s.again)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.study.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .id("again")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            askThread(s)
            if gotIt, checkIndex < s.checks.count {
                check(s, s.checks[checkIndex]).id("check")
            }
        }
    }

    @ViewBuilder private func askThread(_ s: LessonStep) -> some View {
        ForEach(Array(asks.enumerated()), id: \.offset) { _, qa in
            VStack(alignment: .leading, spacing: 10) {
                Text(qa.q).font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Professor", systemImage: "graduationcap.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.study)
                    NoteText(markdown: qa.a)
                }
                .card()
            }
        }
        if asking {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about this step", text: $question, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line) }
                        .onSubmit { Task { await ask(s, question) } }
                    Button { Task { await ask(s, question) } } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Theme.study, in: Circle())
                    }
                    .buttonStyle(CardPress())
                    .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if busy, !question.isEmpty || asks.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text("Professor is answering…").foregroundStyle(.secondary) }
                        .font(.subheadline)
                }
            }
            .transition(.opacity)
        } else if !gotIt || result != nil {
            HStack(spacing: 8) {
                Chip(title: asks.isEmpty ? "Ask Professor" : "Ask more", systemImage: "questionmark.bubble") {
                    withAnimation(.snappy) { asking = true }
                    typing = true
                }
                Spacer()
            }
        }
    }

    private func check(_ s: LessonStep, _ c: LessonCheck) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(checkIndex == 0 ? "Check" : "One more", systemImage: checkIndex == 0 ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.study)
            MathText.text(c.question, style: .title3).font(.title3.weight(.medium)).lineSpacing(3)
            if c.isChoice {
                VStack(spacing: 10) {
                    ForEach(c.options ?? [], id: \.letter) { option in
                        Button { Task { await answer(s, c, option.letter) } } label: {
                            LessonOptionRow(option: option, mark: mark(option))
                        }
                        .buttonStyle(.plain)
                        .disabled(result != nil || busy)
                    }
                }
            } else {
                TextField("Your answer, in your own words", text: $written, axis: .vertical)
                    .lineLimit(3...8)
                    .padding(14)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line) }
                    .disabled(result != nil || busy)
                if busy {
                    HStack(spacing: 10) { ProgressView(); Text("Professor is reading it…").foregroundStyle(.secondary) }
                }
            }
            if let result { verdict(result) }
        }
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func mark(_ option: QuizOption) -> OptionRow.Mark {
        guard let result else { return .plain }
        if option.letter == result.key { return .key }
        return option.letter == result.answer ? .wrong : .plain
    }

    private func verdict(_ r: LessonCheckResult) -> some View {
        let right = r.correct == true, partly = !right && (r.awarded ?? 0) > 0, unmarked = r.correct == nil
        let color: Color = unmarked ? .secondary : right ? Theme.study : partly ? .yellow : .orange
        return VStack(alignment: .leading, spacing: 10) {
            Label(unmarked ? "Compare it with the answer" : right ? "Right" : partly ? "Partly right" : "Not quite",
                  systemImage: unmarked ? "text.magnifyingglass" : right ? "checkmark.circle.fill"
                  : partly ? "circle.lefthalf.filled" : "xmark.circle.fill")
                .font(.headline).foregroundStyle(color)
            if let feedback = r.feedback, !feedback.isEmpty {
                MathText.text(feedback).font(.subheadline).lineSpacing(2)
            }
            if !right, let why = r.keyWhy, !why.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE ANSWER IS \(r.key ?? "")").font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                    MathText.text(why).font(.subheadline).lineSpacing(2)
                }
            }
            if let expected = r.expected, !expected.isEmpty, !right {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A GOOD ANSWER HAS").font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    MathText.text(expected).font(.subheadline).lineSpacing(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Explaining it back

    private var explain: some View {
        VStack(alignment: .leading, spacing: 16) {
            TopBlock("Explain it back", overline: lesson.topic.title) {
                Text("In your own words, as if to a friend who missed the lesson. The best way to find what didn't stick. Tap the microphone on the keyboard to say it instead.")
                    .foregroundStyle(.secondary)
            }
            TextField("What this topic is about, and how it works…", text: $explanation, axis: .vertical)
                .lineLimit(6...16)
                .focused($typing)
                .padding(14)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line) }
                .disabled(busy)
            if busy {
                HStack(spacing: 10) { ProgressView(); Text("Professor is reading it…").foregroundStyle(.secondary) }.card()
            }
        }
    }

    // MARK: How it went

    private var outcome: some View {
        let explained = lesson.explained
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Theme.study)
                .padding(.top, 16)
            TopBlock(headline(explained?.verdict), overline: lesson.topic.title) {
                if let feedback = explained?.feedback, !feedback.isEmpty {
                    MathText.text(feedback).foregroundStyle(.secondary)
                } else {
                    Text("All \(steps.count) steps done.").foregroundStyle(.secondary)
                }
            }
            if let explained {
                if !explained.got.isEmpty { points("What you got", explained.got, "checkmark.circle.fill", Theme.study) }
                if !explained.missing.isEmpty { points("To work on", explained.missing, "exclamationmark.circle.fill", .orange) }
                let review = explained.review.filter { (1...steps.count).contains($0) }
                if !review.isEmpty {
                    DetailCard("Look at again", padding: 0) {
                        ForEach(Array(review.enumerated()), id: \.offset) { i, n in
                            if i > 0 { RowDivider(leading: 16) }
                            Button { open(step: n - 1) } label: {
                                HStack {
                                    Text("\(n)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.study)
                                        .frame(width: 24)
                                    Text(steps[n - 1].title).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPress())
                        }
                    }
                }
            }
            DetailCard("The key ideas", padding: 0) {
                ForEach(steps) { s in
                    if s.n > 1 { RowDivider(leading: 16) }
                    Button { open(step: s.n - 1) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(s.n)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.study).frame(width: 24)
                            MathText.text(s.keyIdea).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                }
            }
        }
    }

    private func headline(_ verdict: String?) -> String {
        switch verdict {
        case "solid": "You've got it"
        case "partly": "Nearly there"
        case "not_yet": "Not yet"
        default: "Lesson done"
        }
    }

    private func points(_ title: String, _ items: [String], _ symbol: String, _ color: Color) -> some View {
        DetailCard(title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Label { MathText.text(item) } icon: { Image(systemName: symbol).foregroundStyle(color) }
                }
            }
        }
    }

    // MARK: The bottom bar

    @ViewBuilder private var bottom: some View {
        switch phase {
        case .intro:
            VStack(spacing: 8) {
                if lesson.finished {
                    big("Go through it again", filled: true) { restart() }
                } else if lesson.at > 0, lesson.at < steps.count {
                    big("Go on from step \(lesson.at + 1)", filled: true) { open(step: lesson.at) }
                    small("Start over") { open(step: 0) }
                } else if lesson.at >= steps.count {
                    big("Explain it back", filled: true) { withAnimation(.snappy) { phase = .explain } }
                } else {
                    big("Start", filled: true) { open(step: 0) }
                }
            }
        case .step(let i):
            stepBar(steps[i], i)
        case .explain:
            VStack(spacing: 8) {
                big(busy ? "Reading…" : "Check my understanding", filled: true) { Task { await finish(explaining: true) } }
                    .disabled(busy || explanation.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                small("Skip") { Task { await finish(explaining: false) } }.disabled(busy)
            }
        case .result:
            VStack(spacing: 8) {
                if let next = lesson.next {
                    big("Next: \(next.title)", filled: true) { self.next(next) }
                    HStack(spacing: 8) {
                        big("Practise this topic", filled: false) { practise() }
                        big("Done", filled: false) { close() }
                    }
                } else {
                    big("Practise this topic", filled: true) { practise() }
                    big("Done", filled: false) { close() }
                }
            }
        }
    }

    @ViewBuilder private func stepBar(_ s: LessonStep, _ i: Int) -> some View {
        let check = checkIndex < s.checks.count ? s.checks[checkIndex] : nil
        if asking, !asks.isEmpty || !question.isEmpty || busy {
            big("Back to the step", filled: false) { withAnimation(.snappy) { asking = false; typing = false } }
        } else if !gotIt {
            HStack(spacing: 10) {
                pill(anotherWay ? "Still not clear" : "Not quite", anotherWay ? "questionmark" : "arrow.uturn.left", .orange) {
                    voice.stop()
                    if anotherWay {
                        withAnimation(.snappy) { asking = true }
                        Task { await ask(s, "I still don't get it. Explain it differently, step by step, with a simple example.") }
                    } else {
                        withAnimation(.snappy) { anotherWay = true }
                    }
                }
                pill(anotherWay ? "Got it now" : "Got it", "checkmark", Theme.study) {
                    voice.stop()
                    withAnimation(.snappy) { gotIt = true; asking = false }
                }
            }
        } else if let result {
            let more = result.correct != true && checkIndex + 1 < s.checks.count
            if more {
                HStack(spacing: 10) {
                    big("Move on", filled: false) { advance(from: i) }
                    big("One more question", filled: true) {
                        withAnimation(.snappy) { self.result = nil; written = ""; checkIndex += 1 }
                    }
                }
            } else {
                big("Continue", filled: true) { advance(from: i) }
            }
        } else if let check, !check.isChoice {
            big(busy ? "Reading…" : "Check", filled: true) { Task { await answer(s, check, written) } }
                .disabled(busy || written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if check == nil {
            big("Continue", filled: true) { advance(from: i) }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func big(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
                .font(.body.weight(.semibold)).foregroundStyle(filled ? .white : Theme.study)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(filled ? Theme.study : Theme.study.opacity(0.14), in: Capsule())
        }
        .buttonStyle(CardPress())
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.subheadline.weight(.medium)).foregroundStyle(Theme.study)
            .frame(height: 30)
    }

    private func pill(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold)).foregroundStyle(color)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(CardPress())
        .disabled(busy)
    }

    // MARK: Moving

    private func open(step i: Int) {
        voice.stop()
        withAnimation(.snappy) {
            gotIt = false; anotherWay = false; checkIndex = 0; result = nil; written = ""
            asks = []; asking = false; question = ""; error = nil
            phase = .step(i)
        }
    }

    private func advance(from i: Int) {
        let done = i + 1
        save(at: max(lesson.at, done))
        if done < steps.count {
            open(step: done)
        } else {
            voice.stop()
            withAnimation(.snappy) { phase = lesson.finished ? .result : .explain }
        }
    }

    private func save(at: Int) {
        guard at != lesson.at else { return }
        lesson.at = at
        let id = lesson.id
        Task { _ = try? await env.api.lessonProgress(id, at: at) }
    }

    // MARK: Calls

    private func answer(_ s: LessonStep, _ c: LessonCheck, _ given: String) async {
        let given = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let got = try await env.api.checkLesson(lesson.id, step: s.n, check: c.n, answer: given)
            withAnimation(.snappy) {
                result = got
                if got.correct == false { anotherWay = true }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ask(_ s: LessonStep, _ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let answer = try await env.api.askLesson(lesson.id, step: s.n, question: text, history: asks)
            withAnimation(.snappy) {
                asks.append(LessonQA(q: text, a: answer))
                question = ""
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(explaining: Bool) async {
        busy = true
        defer { busy = false }
        typing = false
        let text = explaining ? explanation.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        do {
            lesson = try await env.api.finishLesson(lesson.id, explanation: text)
            error = nil
            withAnimation(.snappy) { phase = .result }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A choice in a lesson's check: its maths drawn (`inline=true`), marked once it's answered.
private struct LessonOptionRow: View {
    let option: QuizOption
    let mark: OptionRow.Mark

    var body: some View {
        HStack(spacing: 12) {
            Text(option.letter)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mark == .plain ? Color.primary : .white)
                .frame(width: 28, height: 28)
                .background(badge, in: Circle())
            MathText.text(option.text).frame(maxWidth: .infinity, alignment: .leading).lineSpacing(2)
                .multilineTextAlignment(.leading)
            if mark == .key { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.study) }
            if mark == .wrong { Image(systemName: "xmark").fontWeight(.semibold).foregroundStyle(.orange) }
        }
        .padding(14)
        .background(mark == .plain ? Theme.row : badge.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(mark == .plain ? Theme.line : badge, lineWidth: mark == .plain ? 1 : 1.5)
        }
        .contentShape(Rectangle())
    }

    private var badge: Color {
        switch mark {
        case .plain: Theme.chip
        case .chosen, .key: Theme.study
        case .wrong: .orange
        }
    }
}

/// How the explanation back went, as a small coloured capsule.
struct VerdictBadge: View {
    let verdict: String?

    var body: some View {
        let (title, color): (String, Color) = switch verdict {
        case "solid": ("Got it", Theme.study)
        case "partly": ("Nearly", .yellow)
        case "not_yet": ("Not yet", .orange)
        default: ("Done", Theme.study)
        }
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: Learn the course

/// A course's lessons in order: the one to learn next on top, then every written topic with how far its lesson got.
struct LearnPathView: View {
    let course: StudyCourse
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var path: LessonPath?
    @State private var error: String?
    @State private var learning: LessonTopicRef?

    private var next: LessonPathTopic? { path?.topics.first { $0.id == path?.next } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TopBlock("Learn", overline: course.title) {
                        Text("A lesson per topic, in order: read a short step, check you've got it, then on. Explain it back at the end.")
                            .foregroundStyle(.secondary)
                    }
                    if let error { ErrorCard(text: error) }
                    if let path {
                        if path.topics.isEmpty {
                            Text("No topics written yet. Lessons come from the notebook's topic pages.")
                                .foregroundStyle(.secondary).card()
                        } else {
                            if let next { upNext(next) } else { allDone }
                            topics(path.topics)
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity).card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .pageColumn()
            }
            .pageGlow(Theme.study)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
            .refreshable { await load() }
        }
        .tint(Theme.study)
        .task { await load() }
        .fullScreenCover(item: $learning, onDismiss: { Task { await load() } }) { topic in
            LessonView(topic: topic, course: course.id, courseName: course.title).macCoverSize()
        }
    }

    private func upNext(_ t: LessonPathTopic) -> some View {
        Button { learning = LessonTopicRef(id: t.id, title: t.title) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("UP NEXT").font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(.white.opacity(0.85))
                Text(t.title).font(.title2.bold()).foregroundStyle(.white).multilineTextAlignment(.leading)
                if let summary = t.summary {
                    MathText.text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
                HStack {
                    Text(action(t)).font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(Theme.study)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.white, in: Capsule())
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Theme.study, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(CardPress())
    }

    private var allDone: some View {
        Label("Every topic's lesson is done. Go through any of them again, or practise.", systemImage: "checkmark.seal.fill")
            .foregroundStyle(Theme.study).card()
    }

    private func action(_ t: LessonPathTopic) -> String {
        guard let l = t.lesson else { return "Start" }
        if l.ready, l.at > 0, !l.finished, let count = l.count { return "Go on · step \(min(l.at + 1, count)) of \(count)" }
        return "Start"
    }

    private func topics(_ items: [LessonPathTopic]) -> some View {
        DetailCard("Topics", padding: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                if i > 0 { RowDivider(leading: 56) }
                Button { learning = LessonTopicRef(id: t.id, title: t.title) } label: {
                    HStack(spacing: 12) {
                        mark(t, i + 1).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Text(detail(t)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let verdict = t.lesson?.verdict { VerdictBadge(verdict: verdict) }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPress())
            }
        }
    }

    @ViewBuilder private func mark(_ t: LessonPathTopic, _ n: Int) -> some View {
        if let l = t.lesson, l.finished {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.study)
        } else if let l = t.lesson, l.building {
            ProgressView()
        } else if let l = t.lesson, l.at > 0, let count = l.count {
            ZStack {
                Circle().stroke(Theme.chip, lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(l.at) / CGFloat(max(count, 1)))
                    .stroke(Theme.study, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
        } else {
            Text("\(n)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(Theme.chip, in: Circle())
        }
    }

    private func detail(_ t: LessonPathTopic) -> String {
        let known = t.known + t.learning + t.unseen > 0 ? " · \(t.known) of \(t.known + t.learning + t.unseen) known" : ""
        guard let l = t.lesson else { return "Not written yet" + known }
        if l.building { return "Being written" }
        if l.status == "failed" { return "Couldn't be written · tap to try again" }
        let count = l.count ?? 0
        if l.finished { return "Done" + (l.stale == true ? " · the notes changed" : "") + known }
        if l.at > 0 { return "\(l.at) of \(count) steps" + known }
        return "\(count) steps · ready" + known
    }

    private func load() async {
        do {
            path = try await env.api.lessonPath(course: course.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Reading it aloud

/// Reads a step aloud with the best voice installed for its language; the step's `say` (the maths in words) when
/// it has one.
@MainActor
final class LessonVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if speaking { stop() } else { speak(text) }
    }

    func speak(_ text: String) {
        stop()
        let spoken = Self.spoken(text)
        guard !spoken.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = VoiceController.bestVoice(for: Self.language(of: spoken))
        synthesizer.speak(utterance)
        speaking = true
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    /// The text without figures, formulas on their own lines or LaTeX commands.
    static func spoken(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\$\$[\s\S]*?\$\$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\\(|\\\)|\$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[{}_^]"#, with: " ", options: .regularExpression)
        return VoiceController.spokenText(s)
    }

    /// The language to read in: Italian or English, from the text.
    static func language(of text: String) -> String {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let system = AVSpeechSynthesisVoice.currentLanguageCode()
        if system.hasPrefix(code) { return system }
        return code == "it" ? "it-IT" : code == "en" ? "en-GB" : code
    }
}
