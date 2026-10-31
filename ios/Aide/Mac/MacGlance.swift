import SwiftUI

/// The day at a glance, for the sidebar: the three scores, food against the day's target and habits done. Loaded from
/// the server (the same endpoints as Health, Food and Today), again every few minutes and when the window comes back.
@MainActor
final class MacGlance: ObservableObject {
    static let shared = MacGlance()

    @Published private(set) var scores: HealthScores?
    @Published private(set) var kcal: (eaten: Int, target: Int?)?
    @Published private(set) var habits: (done: Int, of: Int)?

    func load(_ env: AppEnvironment) async {
        guard env.settings.isConfigured else { return }
        async let s = try? env.api.healthScores()
        async let f = try? env.api.food()
        async let h = try? env.api.habits()
        let (scores, food, habits) = await (s, f, h)
        withAnimation(.spring(duration: 1.1, bounce: 0.2)) {
            if let scores { self.scores = scores }
            if let food { kcal = (food.totals.calories, food.goals.calories) }
            if let habits {
                let daily = habits.filter { !$0.isLimit }
                self.habits = (daily.filter(\.doneToday).count, daily.count)
            }
        }
    }
}

/// The glance in the sidebar: three rings that fill as they load, then food and habits as bars. Each opens its page.
struct MacGlanceCard: View {
    @ObservedObject var glance: MacGlance
    var open: (MacSection) -> Void
    /// The rings start empty and fill once the card is on screen.
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(.health) } label: {
                HStack(spacing: 0) {
                    ForEach([ScoreKind.recovery, .strain, .sleep]) { kind in
                        VStack(spacing: 4) {
                            MiniRing(kind: kind, score: shown ? kind.score(glance.scores) : nil, size: 40)
                            Text(kind.name).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Health")

            if let kcal = glance.kcal {
                Button { open(.food) } label: {
                    GlanceBar(icon: "fork.knife", tint: .orange,
                              text: kcal.target.map { "\(kcal.eaten) of \($0) kcal" } ?? "\(kcal.eaten) kcal",
                              part: shown ? kcal.target.map { Double(kcal.eaten) / Double(max($0, 1)) } : 0)
                }
                .buttonStyle(.plain)
                .help("Food")
            }
            if let habits = glance.habits, habits.of > 0 {
                Button { open(.habits) } label: {
                    GlanceBar(icon: "flame.fill", tint: Theme.accent,
                              text: "\(habits.done) of \(habits.of) habits",
                              part: shown ? Double(habits.done) / Double(habits.of) : 0)
                }
                .buttonStyle(.plain)
                .help("Habits")
            }
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            withAnimation(.spring(duration: 1.2, bounce: 0.2).delay(0.15)) { shown = true }
        }
        .onDisappear { shown = false }
    }
}

/// The three scores as concentric rings, for the folded rail.
struct MacGlanceRings: View {
    @ObservedObject var glance: MacGlance
    @State private var shown = false

    var body: some View {
        ZStack {
            ring(.recovery, size: 34)
            ring(.strain, size: 24)
            ring(.sleep, size: 14)
        }
        .frame(width: 40, height: 40)
        .onAppear { withAnimation(.spring(duration: 1.2, bounce: 0.2).delay(0.15)) { shown = true } }
        .onDisappear { shown = false }
    }

    private func ring(_ kind: ScoreKind, size: CGFloat) -> some View {
        let score = shown ? kind.score(glance.scores) ?? 0 : 0
        return ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: Double(score) / 100)
                .stroke(kind.colors(score).last ?? .primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// One score as a small ring with its number, filling from empty.
private struct MiniRing: View {
    let kind: ScoreKind
    let score: Int?
    var size: CGFloat

    var body: some View {
        let colors = kind.colors(score)
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: Double(score ?? 0) / 100)
                .stroke(AngularGradient(colors: colors, center: .center), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.last ?? .clear).opacity(0.5), radius: 4)
            Text(score.map(String.init) ?? "–")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
    }
}

/// A line of the glance: an icon, what it says, and a thin bar of how far along.
private struct GlanceBar: View {
    let icon: String
    let tint: Color
    let text: String
    /// 0–1; nil without a target (no bar).
    let part: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(text, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(GlanceLabel(tint: tint))
                .contentTransition(.numericText())
            if let part {
                GeometryReader { box in
                    Capsule().fill(.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint.gradient).frame(width: box.size.width * min(max(part, 0), 1))
                        }
                }
                .frame(height: 4)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct GlanceLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint).frame(width: 14)
            configuration.title.lineLimit(1)
        }
    }
}

/// Habits as a page of its own: every habit with its grid (the phone opens it from Today).
struct MacHabitsPage: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var habits: [Habit] = []

    var body: some View {
        NavigationStack {
            HabitsScreen(habits: $habits)
                .pageGlow(Theme.accent)
        }
        .task { if let h = try? await env.api.habits() { habits = h } }
        .onChange(of: habits) { _, _ in Task { await MacGlance.shared.load(env) } }
    }
}

/// The team's activity as a page: what's waiting, what's coming up, and the feed. A chat picked there opens in Team.
struct MacActivityPage: View {
    @EnvironmentObject private var push: PushService

    var body: some View {
        ActivitySheet(agent: nil, open: { id in
            switch id {
            case "team": push.route = .team
            case "main": push.route = .agent("aide")
            default: push.route = .conversation(id)
            }
        })
    }
}
