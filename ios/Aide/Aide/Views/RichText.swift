import SwiftUI

/// Lays out an assistant reply: paragraphs, headings, bullets, and lines that start with a time
/// ("09:00–10:00 Dentist", "All day Trip") become small event cards.
struct RichText: View {
    let text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(RichText.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    Text(s.markdown).lineSpacing(3)
                case .heading(let s):
                    Text(s.markdown).font(.headline).padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(s.markdown).lineSpacing(3)
                    }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(n).foregroundStyle(.secondary).monospacedDigit()
                        Text(s.markdown).lineSpacing(3)
                    }
                case .event:
                    EmptyView() // always folded into an agenda by parse()
                case .agenda(let title, let events):
                    AgendaBlock(title: title, events: events)
                }
            }
        }
        .foregroundStyle(isError ? Color.red : Color.primary)
        .textSelection(.enabled)
    }

    // MARK: Parsing

    enum Block {
        case paragraph(String), heading(String), bullet(String), numbered(String, String)
        case event(start: String, end: String?, title: String)
        case agenda(title: String?, events: [AgendaEvent])
    }

    struct AgendaEvent: Hashable { let start: String; let end: String?; let title: String }

    private static let timeLine = try! NSRegularExpression(
        pattern: #"^\**(\d{1,2}[:.]\d{2})(?:\s*[–—-]\s*(\d{1,2}[:.]\d{2}))?\**[\s:,\-–—]*(.+)$"#)
    private static let allDayLine = try! NSRegularExpression(
        pattern: #"^\**(All[- ]day)\**[\s:,\-–—]*(.+)$"#, options: .caseInsensitive)

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            var listMarker = false
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)); listMarker = true; break
            }
            if let e = event(in: line) { blocks.append(e); continue }
            if listMarker { blocks.append(.bullet(line)); continue }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               dot != line.startIndex, line[..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.numbered(String(line[...dot]), String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            blocks.append(.paragraph(line))
        }
        return grouped(blocks)
    }

    /// Consecutive events become one agenda block; a short heading line just before it becomes its title.
    private static func grouped(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            guard case .event(let s, let e, let t) = block else { out.append(block); continue }
            let item = AgendaEvent(start: s, end: e, title: t)
            if case .agenda(let title, let events)? = out.last {
                out[out.count - 1] = .agenda(title: title, events: events + [item])
            } else if case .paragraph(let p)? = out.last, p.count < 60, p.hasSuffix(":") || p.hasPrefix("**") || p.hasPrefix("#") {
                out.removeLast()
                out.append(.agenda(title: p.trimmingCharacters(in: CharacterSet(charactersIn: "*:# ")), events: [item]))
            } else if case .heading(let h)? = out.last {
                out.removeLast()
                out.append(.agenda(title: h, events: [item]))
            } else {
                out.append(.agenda(title: nil, events: [item]))
            }
        }
        return out
    }

    private static func event(in line: String) -> Block? {
        let range = NSRange(line.startIndex..., in: line)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: line).map { String(line[$0]) }
        }
        if let m = timeLine.firstMatch(in: line, range: range), let start = group(m, 1), let title = group(m, 3) {
            return .event(start: start.replacingOccurrences(of: ".", with: ":"),
                          end: group(m, 2)?.replacingOccurrences(of: ".", with: ":"), title: tidy(title))
        }
        if let m = allDayLine.firstMatch(in: line, range: range), let title = group(m, 2) {
            return .event(start: "All day", end: nil, title: tidy(title))
        }
        return nil
    }

    /// Drops a stray `**` left over when the bold span started before the title.
    private static func tidy(_ title: String) -> String {
        title.components(separatedBy: "**").count % 2 == 0
            ? title.replacingOccurrences(of: "**", with: "") : title
    }
}

/// One day's events as a single card: a timeline with the time on the left.
private struct AgendaBlock: View {
    let title: String?
    let events: [RichText.AgendaEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Label(title, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 10)
            }
            ForEach(Array(events.enumerated()), id: \.offset) { i, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(event.start).font(.subheadline.weight(.semibold)).monospacedDigit()
                        if let end = event.end { Text(end).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .frame(minWidth: 52, alignment: .trailing)
                    VStack(spacing: 0) {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9).padding(.top, 5)
                        if i < events.count - 1 {
                            Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    Text(event.title.markdown)
                        .padding(.bottom, i < events.count - 1 ? 14 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
