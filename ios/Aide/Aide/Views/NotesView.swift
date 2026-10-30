import PDFKit
import SwiftMath
import SwiftUI

/// Study notes as the server writes them for the app (`plain=true`: maths as Unicode, links as text; `latex=true`:
/// formulas on their own lines stay `$$…$$`, drawn by `MathFormula`, and with `inline=true` the maths in sentences
/// is `\(…\)`, drawn by `MathText`): headings, paragraphs, lists, Obsidian callouts (`> [!success]- Answer`, folded
/// when it says `-`), and figures (`![caption](figure:f_…/12)`, a page of a study file).
struct NoteText: View {
    let markdown: String
    /// The page's own notes (not a callout's): its headings get the ids `Contents` jumps to.
    var anchored = false
    @Environment(\.dynamicTypeSize) private var typeSize  // the maths is drawn again at a new text size

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { offset, block in
                switch block {
                case .heading(let level, let s):
                    MathText.text(s, style: level <= 1 ? .title2 : level == 2 ? .title3 : .headline)
                        .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, level <= 2 ? 10 : 4)
                        .id(anchored ? Self.anchor(offset) : nil)
                case .paragraph(let s):
                    MathText.text(s).lineSpacing(3)
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        MathText.text(s).lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        MathText.text(s).lineSpacing(3)
                    }
                case .callout(let kind, let title, let folded, let text):
                    Callout(kind: kind, title: title, folded: folded, text: text)
                case .quote(let s):
                    NoteText(markdown: s)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 3) }
                case .figure(let caption, let file, let page):
                    NoteFigure(caption: caption, file: file, page: page)
                case .math(let latex):
                    MathFormula(latex: latex)
                case .code(let s):
                    Text(s).font(.callout.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    struct Heading: Identifiable, Equatable {
        let id: String
        let level: Int
        let title: String
    }

    /// The headings `Contents` lists (down to `###`), with the ids an `anchored` NoteText gives them.
    static func headings(_ markdown: String) -> [Heading] {
        parse(markdown).enumerated().compactMap { offset, block in
            guard case .heading(let level, let title) = block, level <= 3 else { return nil }
            return Heading(id: anchor(offset), level: level, title: title)
        }
    }

    private static func anchor(_ offset: Int) -> String { "heading-\(offset)" }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, indent: Int)
        case numbered(String, String)
        case callout(kind: String, title: String, folded: Bool, text: String)
        case quote(String)
        case figure(caption: String, file: String, page: Int)
        case math(String)
        case code(String)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted = [Self.unquote(trimmed)]
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(Self.unquote(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                if let m = quoted[0].wholeMatch(of: #/\[!(\w+)\]([-+]?)\s*(.*)/#) {
                    blocks.append(.callout(kind: m.1.lowercased(), title: String(m.3), folded: m.2 == "-",
                                           text: quoted.dropFirst().joined(separator: "\n")))
                } else {
                    blocks.append(.quote(quoted.joined(separator: "\n")))
                }
                continue
            }
            if trimmed.hasPrefix("$$") {
                // $$…$$ on one line or several; a full stop after it is dropped, other text after it is a paragraph.
                flush()
                var latex = String(trimmed.dropFirst(2))
                while !latex.contains("$$"), i < lines.count {
                    latex += "\n" + lines[i]
                    i += 1
                }
                let parts = latex.components(separatedBy: "$$")
                blocks.append(.math(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)))
                let rest = parts.dropFirst().joined(separator: "$$").trimmingCharacters(in: .whitespaces)
                if !rest.allSatisfy({ ".,;:".contains($0) }) { paragraph.append(rest) }
                continue
            }
            if let m = trimmed.wholeMatch(of: #/(#{1,6})\s+(.+)/#) {
                flush()
                blocks.append(.heading(m.1.count, String(m.2)))
            } else if let m = trimmed.wholeMatch(of: #/!\[([^\]]*)\]\(figure:(f_[0-9a-f]+)\/(\d+)\)/#) {
                flush()
                blocks.append(.figure(caption: String(m.1), file: String(m.2), page: Int(m.3) ?? 1))
            } else if trimmed.count >= 3, trimmed.allSatisfy({ "-*_".contains($0) }) {
                flush()
                blocks.append(.rule)
            } else if let m = line.wholeMatch(of: #/(\s*)[-*+]\s+(.*)/#) {
                flush()
                blocks.append(.bullet(String(m.2), indent: m.1.count / 2))
            } else if let m = trimmed.wholeMatch(of: #/(\d+)[.)]\s+(.*)/#) {
                flush()
                blocks.append(.numbered(String(m.1), String(m.2)))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    private static func unquote(_ line: String) -> String {
        var s = line.dropFirst()
        if s.hasPrefix(" ") { s = s.dropFirst() }
        return String(s)
    }
}

/// A formula in LaTeX, drawn like Obsidian does (SwiftMath, its Latin Modern font), scrolling sideways when it's wider
/// than the page. What SwiftMath can't read is shown as the LaTeX itself.
struct MathFormula: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 19

    var body: some View {
        let latex = Self.prepare(latex)
        if Self.mathList(latex) != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                MathLabel(latex: latex, size: size, color: UIColor.label.resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)))
                    .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            Text(self.latex).font(.callout.monospaced()).foregroundStyle(.secondary)
        }
    }

    /// The formula parsed, nil when SwiftMath can't.
    static func mathList(_ latex: String) -> MTMathList? {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil else { return nil }
        unaryAcrossSpaces(list)
        return list
    }

    /// SwiftMath makes a `+` unary after a comma, a relation or an opening bracket (and before them), but only when
    /// they're next to each other: with a space between (`,\;+G`) it stays binary, and the typesetter, which skips
    /// spaces, stops on the pair (an assert: a crash in debug builds). The same rule, across spaces, in every part.
    private static func unaryAcrossSpaces(_ list: MTMathList?) {
        guard let list else { return }
        var prev: MTMathAtom?
        for atom in list.atoms {
            [atom.subScript, atom.superScript].forEach(unaryAcrossSpaces)
            switch atom {
            case let a as MTFraction: [a.numerator, a.denominator].forEach(unaryAcrossSpaces)
            case let a as MTRadical: [a.radicand, a.degree].forEach(unaryAcrossSpaces)
            case let a as MTInner: unaryAcrossSpaces(a.innerList)
            case let a as MTOverLine: unaryAcrossSpaces(a.innerList)
            case let a as MTUnderLine: unaryAcrossSpaces(a.innerList)
            case let a as MTAccent: unaryAcrossSpaces(a.innerList)
            case let a as MTMathColor: unaryAcrossSpaces(a.innerList)
            case let a as MTMathTextColor: unaryAcrossSpaces(a.innerList)
            case let a as MTMathColorbox: unaryAcrossSpaces(a.innerList)
            case let a as MTMathTable: a.cells.joined().forEach(unaryAcrossSpaces)
            default: break
            }
            if atom.type == .space || atom.type == .style { continue }
            if atom.type == .binaryOperator,
               prev.map({ [.binaryOperator, .relation, .open, .punctuation, .largeOperator].contains($0.type) }) ?? true {
                atom.type = .unaryOperator
            }
            if [.relation, .punctuation, .close].contains(atom.type), let p = prev, p.type == .binaryOperator {
                p.type = .unaryOperator
            }
            prev = atom
        }
        if let p = prev, p.type == .binaryOperator { p.type = .unaryOperator }
    }

    /// What the notes write that SwiftMath reads differently: `\dfrac` and `\tfrac`, `\dots`, `\middle|`, `\big(`,
    /// and `cases` rows without an `&`.
    static func prepare(_ latex: String) -> String {
        var s = latex.replacing(#/\\[dt]frac(?![A-Za-z])/#, with: "\\frac")
            .replacing(#/\\dots(?![A-Za-z])/#, with: "\\ldots")
            .replacing(#/\\(?:middle|[Bb]igg?[lrm]?)(?![A-Za-z])\s*/#, with: "")
        s = s.replacing(#/\\begin\{cases\}(?<rows>.*?)\\end\{cases\}/#.dotMatchesNewlines()) { m in
            let rows = m.output.rows.components(separatedBy: "\\\\").map { $0.contains("&") ? $0 : $0 + " &" }
            return "\\begin{cases}" + rows.joined(separator: "\\\\") + "\\end{cases}"
        }
        return s
    }

    private struct MathLabel: UIViewRepresentable {
        let latex: String
        let size: CGFloat
        let color: UIColor

        func makeUIView(context: Context) -> MTMathUILabel {
            let label = MTMathUILabel()
            label.labelMode = .display
            label.textAlignment = .left
            label.backgroundColor = .clear
            return label
        }

        func updateUIView(_ label: MTMathUILabel, context: Context) {
            if context.coordinator.latex != latex {
                label.mathList = MathFormula.mathList(latex)
                context.coordinator.latex = latex
            }
            label.fontSize = size
            label.textColor = color
        }

        func makeCoordinator() -> Drawn { Drawn() }

        final class Drawn {
            var latex: String?
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView label: MTMathUILabel, context: Context) -> CGSize? {
            label.intrinsicContentSize
        }
    }
}

/// Inline markdown whose maths (`\(…\)`, from `inline=true`) is drawn by SwiftMath: each formula a picture on the
/// text's baseline, at the size of its text style and in the text's colour (a template image).
enum MathText {
    static func text(_ s: String, style: UIFont.TextStyle = .body) -> Text {
        let found = s.matches(of: #/\\\((.+?)\\\)/#)
        guard !found.isEmpty else { return Text(s.markdown) }
        // Each formula becomes one private-use character, so the markdown around it (bold, links) is read whole.
        var marked = ""
        var latex: [String] = []
        var last = s.startIndex
        for m in found.prefix(0x1000) {
            marked += s[last..<m.range.lowerBound]
            marked.unicodeScalars.append(Unicode.Scalar(0xE000 + latex.count)!)
            latex.append(String(m.output.1))
            last = m.range.upperBound
        }
        marked += s[last...]
        let attributed = marked.markdown
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        var out = Text(verbatim: "")
        var start = attributed.startIndex
        var i = attributed.startIndex
        while i < attributed.endIndex {
            let next = attributed.characters.index(after: i)
            if let v = attributed.characters[i].unicodeScalars.first?.value, v >= 0xE000, Int(v) - 0xE000 < latex.count {
                if start < i { out = out + Text(AttributedString(attributed[start..<i])) }
                out = out + formula(latex[Int(v) - 0xE000], size: size)
                start = next
            }
            i = next
        }
        if start < attributed.endIndex { out = out + Text(AttributedString(attributed[start...])) }
        return out
    }

    private static func formula(_ latex: String, size: CGFloat) -> Text {
        guard let drawn = image(latex, size: size) else { return Text(verbatim: latex).italic() }
        return Text(Image(uiImage: drawn.image).renderingMode(.template)).baselineOffset(-drawn.descent)
    }

    private final class Drawn {
        let image: UIImage
        let descent: CGFloat
        init(image: UIImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }

    private static let drawn = NSCache<NSString, Drawn>()

    /// The formula drawn in black (tinted where it's shown), Latin Modern a little larger than the text's font so
    /// the two look the same size. Nil when SwiftMath can't read it.
    private static func image(_ latex: String, size: CGFloat) -> Drawn? {
        let key = "\(size)|\(latex)" as NSString
        if let done = drawn.object(forKey: key) { return done }
        guard let list = MathFormula.mathList(MathFormula.prepare(latex)) else { return nil }
        let label = MTMathUILabel()
        label.labelMode = .text
        label.fontSize = size * 1.1
        label.textColor = .black
        label.mathList = list
        let fit = label.intrinsicContentSize
        guard fit.width > 0, fit.height > 0 else { return nil }
        label.frame = CGRect(origin: .zero, size: fit)
        label.layoutSubviews()
        guard let display = label.displayList else { return nil }
        let image = UIGraphicsImageRenderer(size: fit).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: fit.height)
            cg.scaleBy(x: 1, y: -1)  // SwiftMath draws with the origin at the bottom
            display.draw(cg)
        }
        let done = Drawn(image: image.withRenderingMode(.alwaysTemplate), descent: display.descent)
        drawn.setObject(done, forKey: key)
        return done
    }
}

/// An Obsidian callout: an answer to fold open, a tip, a warning.
private struct Callout: View {
    let kind: String
    let title: String
    let folded: Bool
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if folded {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
                } label: {
                    HStack {
                        label
                        Spacer()
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                label
            }
            if !folded || open { NoteText(markdown: text) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var label: some View {
        Label(title.isEmpty ? kind.capitalized : title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch kind {
        case "success", "check", "done": .green
        case "warning", "caution", "attention", "danger", "error", "failure", "bug": .orange
        case "example", "question", "faq", "help": .purple
        case "tip", "hint", "important": .teal
        default: .blue
        }
    }

    private var icon: String {
        switch kind {
        case "success", "check", "done": "checkmark.circle"
        case "warning", "caution", "attention", "danger", "error", "failure", "bug": "exclamationmark.triangle"
        case "question", "faq", "help": "questionmark.circle"
        case "example": "list.bullet"
        case "tip", "hint", "important": "lightbulb"
        default: "info.circle"
        }
    }
}

/// A slide in the notes: that page of the study file, drawn by the server. Tap for the full page.
private struct NoteFigure: View {
    let caption: String
    let file: String
    let page: Int
    @EnvironmentObject private var env: AppEnvironment
    @State private var image: UIImage?
    @State private var failed = false
    @State private var zoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .onTapGesture { zoomed = true }
                } else {
                    Rectangle().fill(Theme.card).aspectRatio(4 / 3, contentMode: .fit)
                        .overlay {
                            if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView() }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line) }
            if !caption.isEmpty {
                Text(caption.markdown).font(.footnote).italic().foregroundStyle(.secondary)
            }
        }
        .task {
            guard image == nil, let data = try? await env.api.fileData(file, page: page), let ui = UIImage(data: data)
            else { failed = image == nil; return }
            image = ui
        }
        .fullScreenCover(isPresented: $zoomed) {
            if let image { ZoomedImage(image: image, caption: caption) }
        }
    }
}

struct ZoomedImage: View {
    let image: UIImage
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geo.size.width * scale * pinch)
                        .frame(minHeight: geo.size.height)
                }
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { scale = min(5, max(1, scale * $0.magnification)) })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            }
            .background(Color.black)
            .navigationTitle(caption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: Pages

/// A page of notes that scrolls, with Contents in the toolbar (from three headings up) to jump to one.
struct NoteScroll<Content: View>: View {
    let headings: [NoteText.Heading]
    @ViewBuilder let content: () -> Content
    @State private var showing = false
    @State private var jump: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .toolbar {
                    if headings.count >= 3 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showing = true } label: { Image(systemName: "list.bullet") }
                                .accessibilityLabel("Contents")
                        }
                    }
                }
                .sheet(isPresented: $showing) {
                    NoteContents(headings: headings) { id in
                        jump = id
                        showing = false
                    }
                }
                .onChange(of: jump) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    jump = nil
                }
        }
    }
}

/// The page's headings, the top ones in bold and the ones under them indented; a tap goes there.
private struct NoteContents: View {
    let headings: [NoteText.Heading]
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let top = headings.map(\.level).min() ?? 1
        NavigationStack {
            List(headings) { heading in
                Button { pick(heading.id) } label: {
                    MathText.text(heading.title, style: heading.level == top ? .headline : .body)
                        .font(heading.level == top ? .headline : .body)
                        .foregroundStyle(heading.level == top ? .primary : .secondary)
                        .padding(.leading, CGFloat(heading.level - top) * 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A topic of a course's notebook: the notes, then its flashcards.
struct TopicPageView: View {
    let topic: NotebookTopic
    @EnvironmentObject private var env: AppEnvironment
    @State private var page: TopicPage?
    @State private var error: String?

    var body: some View {
        NoteScroll(headings: headings) {
            VStack(alignment: .leading, spacing: 16) {
                Text(topic.title).font(.largeTitle.bold())
                if let summary = page?.summary ?? topic.summary {
                    Text(summary.markdown).font(.title3).foregroundStyle(.secondary)
                }
                if let page {
                    NoteText(markdown: page.body ?? "", anchored: true)
                    if let cards = page.cardsList, !cards.isEmpty { Flashcards(cards: cards).id("flashcards") }
                    if let sources = page.sources, !sources.isEmpty {
                        Text("From " + sources.joined(separator: "; "))
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                } else {
                    SkeletonText()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var headings: [NoteText.Heading] {
        guard let page else { return [] }
        let cards = page.cardsList?.isEmpty == false
        return NoteText.headings(page.body ?? "") + (cards ? [.init(id: "flashcards", level: 2, title: "Flashcards")] : [])
    }

    private func load() async {
        do {
            page = try await env.api.topic(topic.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Question on the front, answer on the back: tap to turn.
private struct Flashcards: View {
    let cards: [Flashcard]
    @State private var turned: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Flashcards").font(.title3.bold()).padding(.top, 12)
            Text("Tap a card to see the answer. They're also in Obsidian for Spaced Repetition.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                let open = turned.contains(index)
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.q.markdown).font(.body.weight(.medium))
                    if open {
                        Divider()
                        Text(card.a.markdown).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if open { turned.remove(index) } else { turned.insert(index) }
                    }
                }
            }
        }
    }
}

/// A page of markdown with a title: the course's Introduction.
struct NotePage: View {
    let title: String
    let markdown: String

    var body: some View {
        NoteScroll(headings: NoteText.headings(markdown)) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.largeTitle.bold())
                NoteText(markdown: markdown, anchored: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A page whose markdown is fetched when it opens: the formula sheet, a topic's exercises.
struct LoadedNotePage: View {
    let title: String
    var subtitle: String? = nil
    let load: () async throws -> String
    @State private var markdown: String?
    @State private var error: String?

    var body: some View {
        NoteScroll(headings: markdown.map(NoteText.headings) ?? []) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.largeTitle.bold())
                if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                if let markdown {
                    NoteText(markdown: markdown, anchored: true)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                } else {
                    SkeletonText()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetch() }
        .refreshable { await fetch() }
    }

    private func fetch() async {
        do {
            markdown = try await load()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A lecture's notes, or where they are while they're being written.
struct LectureView: View {
    let lecture: Lecture
    @EnvironmentObject private var env: AppEnvironment
    @State private var full: Lecture?
    @State private var error: String?

    var body: some View {
        NoteScroll(headings: full?.notes.map(NoteText.headings) ?? []) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lecture.title ?? "Lecture").font(.largeTitle.bold())
                    Text(lecture.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let notes = full?.notes, !notes.isEmpty {
                    NoteText(markdown: notes, anchored: true)
                } else if let current = full ?? Optional(lecture), current.isWorking || current.status == "failed" {
                    Label(current.statusText, systemImage: current.status == "failed" ? "exclamationmark.triangle" : "hourglass")
                        .foregroundStyle(current.status == "failed" ? .red : .secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                } else if full == nil {
                    SkeletonText()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            full = try await env.api.lecture(lecture.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Lecture {
    var date: Date? { recordedAt.flatMap(Wire.parse) }

    var subtitle: String {
        var parts = [date?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }
        if let s = durationS, s > 0 { parts.append("\(s / 60) min") }
        if isWorking || status == "failed" { parts.append(statusText) }
        return parts.joined(separator: " · ")
    }

    var statusText: String {
        switch status {
        case "queued": "Waiting to be written up"
        case "transcribing": "Transcribing"
        case "writing": "Writing the notes"
        case "failed": error.map { "Failed: \($0)" } ?? "Failed"
        default: "Ready"
        }
    }
}

/// A study file's PDF, fetched once.
struct PDFSheet: View {
    let file: StudyFile
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                let data = try await env.api.fileData(file.id)
                guard let pdf = PDFDocument(data: data) else { throw APIError.badResponse }
                document = pdf
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
