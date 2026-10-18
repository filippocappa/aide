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

/// One day's events as a single card, each event a tile in its own colour.
private struct AgendaBlock: View {
    let title: String?
    let events: [RichText.AgendaEvent]

    private static let palette: [Color] = [
        Color(red: 0.24, green: 0.49, blue: 0.69), // ocean
        Color(red: 0.42, green: 0.56, blue: 0.44), // sage
        Color(red: 0.56, green: 0.35, blue: 0.61), // plum
        Color(red: 0.85, green: 0.64, blue: 0.25), // amber
        Color(red: 0.78, green: 0.36, blue: 0.48), // rose
        Color(red: 0.16, green: 0.62, blue: 0.56), // teal
    ]

    /// Stable per title, so a recurring event keeps its colour from day to day.
    private func color(for event: RichText.AgendaEvent) -> Color {
        if event.start == "All day" { return Theme.accent }
        var h: UInt32 = 5381
        for u in event.title.lowercased().unicodeScalars { h = h &* 33 &+ u.value }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label(title, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 2)
            }
            ForEach(events, id: \.self) { event in
                let tint = color(for: event)
                HStack(spacing: 12) {
                    Capsule().fill(tint).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title.markdown).font(.body.weight(.medium))
                        Text(event.end.map { "\(event.start) – \($0)" } ?? event.start)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .fixedSize(horizontal: false, vertical: true)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
