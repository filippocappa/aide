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
                case .event(let start, let end, let title):
                    EventCard(start: start, end: end, title: title)
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
    }

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
        return blocks
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

private struct EventCard: View {
    let start: String
    let end: String?
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(start).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let end { Text(end).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .frame(minWidth: 52, alignment: .trailing)
            Capsule().fill(Theme.accent).frame(width: 3)
            Text(title.markdown).font(.body)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
