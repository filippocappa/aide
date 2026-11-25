import PDFKit
import SwiftUI

// Ask Professor (#64, #65; docs/API.md "Ask Professor"): a question about a passage the user picked, or about a
// course file open beside Professor, answered on the fast model, with follow-ups in a thread. The course chat keeps
// each thread as one message, drawn folded (`AskEntryCard`).

/// A page's "Ask Professor" for its passages: set, every block of a `NoteText` under it offers it (long press on the
/// phone, right click on the Mac), with the block's text.
private struct AskPassageKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var askPassage: ((String) -> Void)? {
        get { self[AskPassageKey.self] }
        set { self[AskPassageKey.self] = newValue }
    }
}

/// What a passage asked about needs: the text and where it's from.
struct AskRequest: Identifiable, Hashable {
    let id = UUID()
    var course: Int?
    var source: AskSource
    var passage: String?
    var thread: AskThread? = nil
}

extension View {
    /// Long press (phone) or right click (Mac) on a block of notes: Ask Professor about it, or Copy.
    func askable(_ text: String, ask: ((String) -> Void)?) -> some View {
        modifier(Askable(text: text, ask: ask))
    }

    /// Ask Professor about passages on this page: the sheet opens with the passage picked.
    func askingProfessor(course: Int?, source: AskSource?) -> some View {
        modifier(AskingProfessor(course: course, source: source))
    }
}

private struct Askable: ViewModifier {
    let text: String
    let ask: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let ask {
            content.contextMenu {
                Button { ask(text) } label: { Label("Ask Professor", systemImage: "questionmark.bubble") }
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        } else {
            content
        }
    }
}

private struct AskingProfessor: ViewModifier {
    let course: Int?
    let source: AskSource?
    @State private var asking: AskRequest?

    func body(content: Content) -> some View {
        if let source {
            content
                .environment(\.askPassage) { asking = AskRequest(course: course, source: source, passage: $0) }
                .sheet(item: $asking) { AskSheet(request: $0) }
        } else {
            content
        }
    }
}

// MARK: The thread

@MainActor
final class AskModel: ObservableObject {
    @Published private(set) var thread: AskThread?
    @Published private(set) var passage: String?
    @Published private(set) var asked: String?  // waiting for its answer
    @Published var error: String?
    var source: AskSource
    let course: Int?

    init(course: Int?, source: AskSource, passage: String? = nil, thread: AskThread? = nil) {
        self.course = course
        self.source = source
        self.passage = thread?.passage ?? passage
        self.thread = thread
    }

    var busy: Bool { asked != nil }

    /// A new thread about another passage (text selected in the PDF).
    func start(passage: String?) {
        thread = nil
        self.passage = passage
        error = nil
    }

    func send(_ question: String?, action: String? = nil, api: APIClient) async {
        guard !busy else { return }
        let typed = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        asked = action == "explain" ? "Explain this page" : action == "quiz" ? "Quiz me on these pages"
            : (typed?.isEmpty == false ? typed! : "Explain this.")
        error = nil
        defer { asked = nil }
        do {
            thread = try await api.ask(AskBody(course: course, source: source, passage: thread == nil ? passage : nil,
                                               question: typed?.isEmpty == false ? typed : nil, action: action,
                                               thread: thread?.id))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The passage on top, the questions and answers, page chips under a file's answers, and the message box with the
/// microphone. `cite`: a chip tapped (the reader turns the PDF there).
struct AskThreadView: View {
    @ObservedObject var model: AskModel
    var cite: ((PageCitation) -> Void)? = nil
    /// The file's quick actions (Explain this page, Quiz me on these pages).
    var quickActions = false
    /// Asked once it appears: "Explain this." for a passage with no thread yet.
    var askAtOnce = false
    @EnvironmentObject private var env: AppEnvironment
    @State private var draft = ""
    @State private var sent = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let passage = model.passage, !passage.isEmpty { quote(passage) }
                        if let place = model.thread?.place {
                            Text(place).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array((model.thread?.turns ?? []).enumerated()), id: \.offset) { _, turn in
                            AskTurnView(turn: turn, cite: cite)
                        }
                        if let asked = model.asked {
                            question(asked)
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Professor is answering…").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: model.thread?.turns.count) { withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.asked) { withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
            }
            if quickActions, !model.busy {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Explain this page", systemImage: "text.magnifyingglass") {
                            Task { await model.send(nil, action: "explain", api: env.api) }
                        }
                        Chip(title: "Quiz me on these pages", systemImage: "checklist") {
                            Task { await model.send(nil, action: "quiz", api: env.api) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 4)
            }
            MessageBox(model.thread == nil && model.passage == nil ? "Ask Professor" : "Ask more", text: $draft,
                       focused: $focused, reset: sent, tint: Theme.study, onReturn: { send() }) {
                DictateButton { text in
                    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = typed.isEmpty ? text : typed + " " + text
                }
                SendButton(enabled: canSend, action: send)
            }
        }
        .environment(\.askPassage, nil) // its answers aren't asked about again from inside
        .task {
            if askAtOnce, model.thread == nil, model.passage != nil {
                await model.send(nil, api: env.api)
            }
        }
    }

    private var canSend: Bool {
        !model.busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        $draft.clearMessage()
        sent += 1
        Task { await model.send(text, api: env.api) }
    }

    private func quote(_ passage: String) -> some View {
        Text(passage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(8)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.study.opacity(0.6)).frame(width: 3) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func question(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A question and Professor's answer, with the pages it used as chips.
struct AskTurnView: View {
    let turn: AskTurn
    var cite: ((PageCitation) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.action == "explain" ? "Explain this page" : turn.action == "quiz" ? "Quiz me on these pages" : turn.q)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Label("Professor", systemImage: "graduationcap.fill").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.study)
                NoteText(markdown: turn.a)
                if let cite, !turn.citations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(turn.citations, id: \.self) { c in
                                Button { cite(c) } label: {
                                    Label("p. \(c.page)", systemImage: c.text == nil ? "doc" : "highlighter")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Theme.study.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Theme.study)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Go to page \(c.page)")
                            }
                        }
                    }
                }
            }
            .card()
        }
    }
}

/// The thread in a sheet: from a passage in the notes or a lesson, or opened again from the course chat.
struct AskSheet: View {
    @StateObject private var model: AskModel
    @Environment(\.dismiss) private var dismiss
    private let startsAtOnce: Bool

    init(request: AskRequest) {
        _model = StateObject(wrappedValue: AskModel(course: request.course, source: request.source,
                                                    passage: request.passage, thread: request.thread))
        startsAtOnce = request.thread == nil && request.passage != nil
    }

    var body: some View {
        NavigationStack {
            AskThreadView(model: model, askAtOnce: startsAtOnce)
                .navigationTitle("Ask Professor")
                .navigationBarTitleDisplayMode(.inline)
                .macSheetTitle("Ask Professor")
                #if os(iOS)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                #endif
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: In the course chat

/// The course chat's message for a thread: "Asked about: …" folded, the questions and answers when opened, and
/// Continue to ask more.
struct AskEntryCard: View {
    let thread: AskThread
    @State private var open = false
    @State private var asking: AskRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.study)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Asked about: \(thread.place)").font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        if let passage = thread.passage, !passage.isEmpty {
                            Text(passage).font(.footnote).foregroundStyle(.secondary).lineLimit(open ? 6 : 2)
                                .multilineTextAlignment(.leading)
                        }
                        Text(thread.turns.count == 1 ? "1 question" : "\(thread.turns.count) questions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(thread.turns.enumerated()), id: \.offset) { _, turn in AskTurnView(turn: turn) }
                Chip(title: "Ask more", systemImage: "questionmark.bubble", style: .prominent, tint: Theme.study) {
                    asking = AskRequest(course: thread.course, source: thread.source, passage: thread.passage,
                                        thread: thread)
                }
            }
        }
        .card(padding: 14)
        .sheet(item: $asking) { AskSheet(request: $0) }
    }
}

// MARK: A course file with Professor beside it (#65)

/// A study file's PDF, with Professor beside it when it's a course's: side by side on a wide screen (the Mac, the
/// iPad), a panel pulled up from the bottom on the phone. Text selected in the PDF can be asked about (the panel's
/// button, or Ask Professor in its menu); page chips under an answer turn the PDF there and highlight the words.
struct FileReader: View {
    let file: StudyFile
    let document: PDFDocument
    var page: Int?
    @StateObject private var model: AskModel
    @State private var current: Int
    @State private var selection = ""
    @State private var target: PageCitation?
    @State private var panel = false  // the phone's panel pulled up
    @State private var beside = true  // the wide screen's column shown

    init(file: StudyFile, document: PDFDocument, page: Int?) {
        self.file = file
        self.document = document
        self.page = page
        _current = State(initialValue: page ?? 1)
        _model = StateObject(wrappedValue: AskModel(course: file.course, source: AskSource(file: file.id, page: page)))
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 720
            Group {
                if wide {
                    HStack(spacing: 0) {
                        pdf
                        if beside {
                            Divider()
                            professor.frame(width: min(420, geo.size.width * 0.4))
                        }
                    }
                } else {
                    pdf.safeAreaInset(edge: .bottom, spacing: 0) { drawer(height: geo.size.height) }
                }
            }
            .toolbar {
                if wide {
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation(.snappy) { beside.toggle() } } label: {
                            Label("Professor", systemImage: beside ? "sidebar.trailing" : "graduationcap")
                        }
                        .help(beside ? "Hide Professor" : "Ask Professor about this file")
                    }
                }
            }
        }
        .onChange(of: current) { model.source = AskSource(file: file.id, page: current) }
    }

    private var pdf: some View {
        PDFReaderView(document: document, page: page, current: $current, selection: $selection, target: $target,
                      ask: { askAbout($0) })
    }

    private func askAbout(_ text: String) {
        model.start(passage: text)
        panel = true
        beside = true
        Task { await model.send(nil, api: api) }
    }

    @EnvironmentObject private var env: AppEnvironment
    private var api: APIClient { env.api }

    private var professor: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Professor", systemImage: "graduationcap.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.study)
                Spacer()
                Text("p. \(current) of \(document.pageCount)").font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                if model.thread != nil || model.passage != nil {
                    Button { model.start(passage: nil) } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.plain).foregroundStyle(Theme.study)
                        .accessibilityLabel("New question")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            selectionBar
            AskThreadView(model: model, cite: go, quickActions: true)
        }
    }

    /// Text selected in the PDF: ask about it.
    @ViewBuilder private var selectionBar: some View {
        let picked = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !picked.isEmpty, picked != model.passage {
            Button { askAbout(picked) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                    Text("Ask about “\(picked)”").lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.study)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.study.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    /// The phone's panel: a bar to pull up (and the selection to ask about), Professor at about half the screen.
    private func drawer(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 8)
            if panel {
                professor.frame(height: height * 0.55)
            } else {
                selectionBar.padding(.top, 8)
                Button { withAnimation(.snappy) { panel = true } } label: {
                    Label("Ask Professor about this file", systemImage: "graduationcap.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.study)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            withAnimation(.snappy) { panel = g.translation.height < 0 }
        })
    }

    private func go(_ c: PageCitation) {
        guard c.file == file.id else { return }
        target = c
        if !beside { beside = true }
    }
}

/// PDFKit's view, telling the page on screen and the selected text, turning to a cited page (its words highlighted
/// when found), with Ask Professor in the selection's menu.
struct PDFReaderView: UIViewRepresentable {
    let document: PDFDocument
    var page: Int?
    @Binding var current: Int
    @Binding var selection: String
    @Binding var target: PageCitation?
    var ask: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = AskablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.ask = ask
        let c = context.coordinator
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: .PDFViewSelectionChanged, object: view)
        if let page, page > 1, let target = document.page(at: page - 1) {
            DispatchQueue.main.async { view.go(to: target) } // once it's laid out
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        (view as? AskablePDFView)?.ask = ask
        if view.document !== document { view.document = document }
        if let target {
            DispatchQueue.main.async {
                Self.turn(view, to: target)
                self.target = nil
            }
        }
    }

    /// The page, and its words picked out when PDFKit finds them there (the whole run, else its first words).
    static func turn(_ view: PDFView, to c: PageCitation) {
        guard let document = view.document, let page = document.page(at: c.page - 1) else { return }
        if let text = c.text {
            let words = text.split(separator: " ")
            for tryText in [text, words.prefix(max(2, words.count / 2)).joined(separator: " ")] {
                let found = document.findString(tryText, withOptions: [.caseInsensitive])
                    .first { $0.pages.contains(page) }
                if let found {
                    #if os(macOS)
                    found.color = NSColor.systemYellow.withAlphaComponent(0.5)
                    #else
                    found.color = UIColor.systemYellow.withAlphaComponent(0.5)
                    #endif
                    view.highlightedSelections = [found]
                    view.go(to: found)
                    return
                }
            }
        }
        view.highlightedSelections = nil
        view.go(to: page)
    }

    final class Coordinator: NSObject {
        var parent: PDFReaderView
        init(_ parent: PDFReaderView) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            let n = index + 1
            if parent.current != n { parent.current = n }
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            let text = (view.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if parent.selection != text { parent.selection = String(text.prefix(4000)) }
        }
    }
}

/// A PDFView whose selection menu has Ask Professor.
final class AskablePDFView: PDFView {
    var ask: ((String) -> Void)?

    private var picked: String? {
        let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if ask != nil, picked != nil {
            let item = NSMenuItem(title: "Ask Professor", action: #selector(askPicked), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func askPicked() {
        if let picked { ask?(picked) }
    }
    #else
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, ask != nil, picked != nil else { return }
        let action = UIAction(title: "Ask Professor", image: UIImage(systemName: "questionmark.bubble")) { [weak self] _ in
            if let picked = self?.picked { self?.ask?(picked) }
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [action]), atStartOfMenu: .root)
    }
    #endif
}
