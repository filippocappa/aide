import SwiftUI

/// The line's number on a tram, bus or metro badge.
struct LineBadge: View {
    let line: String
    let vehicle: String
    /// Smaller, for widgets and the Dynamic Island.
    var compact = false

    private var symbol: String {
        switch vehicle {
        case "Tram": "tram.fill"
        case "Metro": "tram.fill.tunnel"
        case "Train": "train.side.front.car"
        default: "bus.fill"
        }
    }

    var color: Color {
        switch vehicle {
        case "Tram": Color(red: 0.91, green: 0.47, blue: 0.16)
        case "Metro": Color(red: 0.78, green: 0.11, blue: 0.18)
        case "Train": Color(red: 0.30, green: 0.36, blue: 0.42)
        default: Color(red: 0.16, green: 0.42, blue: 0.71)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            Text(line).font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 3 : 5)
        .frame(minWidth: compact ? 40 : 54)
        .background(color, in: RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vehicle) \(line)")
    }
}
