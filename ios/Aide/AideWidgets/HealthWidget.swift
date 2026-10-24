import SwiftUI
import WidgetKit

/// Today's food against the goals, and the habits with a tap to check in (docs/API.md, "Widgets").
struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Health", provider: HealthProvider()) { HealthWidgetView(entry: $0) }
            .configurationDisplayName("Food and habits")
            .description("Calories and macros so far today, and your habits.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct HealthEntry: TimelineEntry {
    let date: Date
    let food: Loaded<FoodDay>?
    let habits: Loaded<HabitList>?
    var agents: [Agent] = [.aide]
    var configured = true

    var fresh: Bool { (food?.fresh ?? true) && (habits?.fresh ?? true) }
}

struct HealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry { HealthEntry(date: Date(), food: nil, habits: nil) }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        provide({ completion($0.entries[0]) }) { await timeline() }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        provide(completion) { await timeline() }
    }

    @MainActor private func timeline() async -> Timeline<HealthEntry> {
        let now = Date()
        guard WidgetAPI.isConfigured else {
            return Timeline(entries: [HealthEntry(date: now, food: nil, habits: nil, configured: false)], policy: .after(now + 3600))
        }
        async let food = WidgetCache.load(FoodDay.self, "/v1/food")
        async let habits = WidgetCache.load(HabitList.self, "/v1/habits")
        let entry = HealthEntry(date: now, food: await food, habits: await habits, agents: await WidgetCache.agents())
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 60)
        return Timeline(entries: [entry], policy: .after(min(now + 30 * 60, midnight)))
    }
}

struct HealthWidgetView: View {
    let entry: HealthEntry
    @Environment(\.widgetFamily) private var family

    /// Coach's colour, as on the Health tab's ring.
    private var coach: Color { entry.agents.agent("coach").tint }

    var body: some View {
        Group {
            if !entry.configured {
                WidgetNote(text: WidgetNote.setUp)
            } else if entry.food == nil && entry.habits == nil {
                WidgetNote(text: "Can't reach Aide. Is Tailscale on?")
            } else {
                switch family {
                case .accessoryCircular: gauge
                case .systemMedium:
                    HStack(spacing: 14) {
                        food
                        Divider()
                        habits(limit: 4)
                    }
                default: food
                }
            }
        }
        .widgetBackground()
        .widgetURL(URL(string: "aide://health"))
    }

    private var totals: FoodTotals { entry.food?.value.totals ?? FoodTotals() }
    private var goals: FoodGoals { entry.food?.value.goals ?? FoodGoals() }

    private var gauge: some View {
        Gauge(value: Double(totals.calories), in: 0...Double(max(goals.calories ?? 2000, 1))) {
            Image(systemName: "fork.knife")
        } currentValueLabel: {
            Text("\(totals.calories)").monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var food: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Food", fresh: entry.fresh)
            HStack(spacing: 10) {
                Ring(value: Double(totals.calories), goal: goals.calories.map(Double.init), color: coach)
                    .frame(width: 54, height: 54)
                    .overlay {
                        VStack(spacing: -2) {
                            Text("\(totals.calories)").font(.subheadline.weight(.bold)).monospacedDigit()
                                .minimumScaleFactor(0.6)
                            Text("kcal").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                if family == .systemSmall, let goal = goals.calories {
                    VStack(alignment: .leading) {
                        Text("\(max(goal - totals.calories, 0))").font(.headline).monospacedDigit()
                        Text("left").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            macro("Protein", totals.proteinG, goals.proteinG)
            macro("Carbs", totals.carbsG, goals.carbsG)
            macro("Fat", totals.fatG, goals.fatG)
        }
        .frame(maxWidth: family == .systemMedium ? 120 : .infinity, alignment: .leading)
    }

    private func macro(_ name: String, _ value: Int, _ goal: Int?) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(goal.map { "\(value)/\($0) g" } ?? "\(value) g").font(.caption2.weight(.medium)).monospacedDigit()
        }
    }

    private func habits(limit: Int) -> some View {
        let list = entry.habits?.value.habits ?? []
        let done = list.filter(\.doneToday).count
        return VStack(alignment: .leading, spacing: 5) {
            WidgetHeader(title: list.isEmpty ? "Habits" : "Habits \(done)/\(list.count)", fresh: entry.fresh)
            if list.isEmpty {
                Text("No habits yet. Ask Coach to start one.").font(.caption).foregroundStyle(.secondary)
            }
            // Still to do first: those are the ones to tap.
            ForEach(Array(list.sorted { !$0.doneToday && $1.doneToday }.prefix(limit))) { habit in
                Button(intent: CheckHabitIntent(id: habit.id, done: !habit.doneToday)) {
                    HStack(spacing: 6) {
                        Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(habit.doneToday ? coach : .secondary)
                        Text(habit.name).font(.subheadline).lineLimit(1)
                            .foregroundStyle(habit.doneToday ? .secondary : .primary)
                        Spacer(minLength: 0)
                        if habit.streak > 1 {
                            Text("\(habit.streak)🔥").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A progress ring; without a goal, a full faint ring.
struct Ring: View {
    let value: Double
    let goal: Double?
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 6)
            if let goal, goal > 0 {
                Circle().trim(from: 0, to: min(value / goal, 1))
                    .stroke(value > goal * 1.05 ? .orange : color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}
