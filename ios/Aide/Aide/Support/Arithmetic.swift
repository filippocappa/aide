import Foundation

/// A sum typed in a number field, like "400/3", "2×30+15" or "(250-40)*0.5": + − × ÷ (also - * / x :), brackets,
/// a comma or a point for decimals. Nil when it isn't one, or it divides by zero.
enum Arithmetic {
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(text)
        guard let value = parser.sum(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// Whether there's more to it than a number, so the field shows what it comes to.
    static func isSum(_ text: String) -> Bool {
        text.contains { "+−-×*x÷/:()".contains($0) }
    }

    private struct Parser {
        private let chars: [Character]
        private var i = 0

        init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace })
        }

        var atEnd: Bool { i == chars.count }

        private var next: Character? { i < chars.count ? chars[i] : nil }

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let c = next, "+−-".contains(c) {
                i += 1
                guard let rhs = product() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = factor() else { return nil }
            while let c = next, "×*xX÷/:".contains(c) {
                i += 1
                guard let rhs = factor() else { return nil }
                if "÷/:".contains(c) {
                    guard rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func factor() -> Double? {
            if let c = next, "−-".contains(c) {
                i += 1
                return factor().map { -$0 }
            }
            if next == "(" {
                i += 1
                guard let value = sum(), next == ")" else { return nil }
                i += 1
                return value
            }
            let start = i
            while let c = next, c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}
