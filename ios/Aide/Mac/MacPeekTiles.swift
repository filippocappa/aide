import SwiftUI

// MARK: - What's on the board

/// A kind of tile on Peek's board. Each is on the board at most once.
enum PeekTileKind: String, Codable, CaseIterable, Identifiable {
    case week, glance, team, waiting, body, habits, food, study, money, weather, bedtime, trams

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .glance: "At a glance"
        case .team: "Your team"
        case .waiting: "Waiting for you"
        case .body: "Body"
        case .habits: "Habits"
        case .food: "Food today"
        case .study: "Study today"
        case .money: "Money"
        case .weather: "Weather"
        case .bedtime: "Bedtime"
        case .trams: "Trams"
        }
    }

    var icon: String {
        switch self {
        case .week: "calendar"
        case .glance: "sun.max"
        case .team: "person.3"
        case .waiting: "tray"
        case .body: "heart"
        case .habits: "checkmark.circle"
        case .food: "fork.knife"
        case .study: "book"
        case .money: "eurosign.circle"
        case .weather: "cloud.sun"
        case .bedtime: "moon.zzz"
        case .trams: "tram"
        }
    }

    /// The colour of the agent whose work it is.
    var tint: Color {
        switch self {
        case .week, .trams: Color(uiColor: UIColor(hex: 0x769AE4))
        case .study: Color(uiColor: UIColor(hex: 0xA284DE))
        case .body, .habits, .food, .bedtime: Color(uiColor: UIColor(hex: 0x65BE99))
        case .money: Color(uiColor: UIColor(hex: 0xCDB360))
        case .glance, .team, .waiting, .weather: Theme.sand
        }
    }

    /// Where a click on the tile goes in Aide's window.
    var section: MacSection? {
        switch self {
        case .week: .today
        case .body, .bedtime: .health
        case .habits: .habits
        case .food: .food
        case .study: .study
        case .money: .money
        case .glance, .team, .waiting, .weather, .trams: nil
        }
    }
}

struct PeekTile: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: PeekTileKind
    /// How many of the board's columns it takes.
    var span = 1
}

/// The board's tiles in order, kept on this Mac. Arranged on the board itself (`MacPeek.arranging`).
@MainActor
final class PeekLayout: ObservableObject {
    static let shared = PeekLayout()
    private static let key = "peekTiles"
    static let standard: [PeekTile] = [
        PeekTile(kind: .week), PeekTile(kind: .glance), PeekTile(kind: .waiting, span: 2), PeekTile(kind: .team),
    ]

    @Published var tiles: [PeekTile] {
        didSet {
            if let data = try? JSONEncoder().encode(tiles) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private init() {
        // Tiles of a kind this version doesn't know are dropped, not the whole board.
        struct Loose: Decodable { let id: UUID; let kind: String; let span: Int }
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let loose = try? JSONDecoder().decode([Loose].self, from: data) {
            tiles = loose.compactMap { t in PeekTileKind(rawValue: t.kind).map { PeekTile(id: t.id, kind: $0, span: t.span) } }
        } else {
            tiles = Self.standard
        }
    }

    var missing: [PeekTileKind] { PeekTileKind.allCases.filter { kind in !tiles.contains { $0.kind == kind } } }
    var kinds: Set<PeekTileKind> { Set(tiles.map(\.kind)) }

    func add(_ kind: PeekTileKind) {
        guard !kinds.contains(kind) else { return }
        tiles.append(PeekTile(kind: kind, span: kind == .waiting ? 2 : 1))
    }

    func remove(_ id: UUID) { tiles.removeAll { $0.id == id } }

    /// The tile `id` takes `target`'s place; the ones between shift over.
    func move(_ id: UUID, to target: UUID) {
        guard let from = tiles.firstIndex(where: { $0.id == id }),
              let to = tiles.firstIndex(where: { $0.id == target }), from != to else { return }
        tiles.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    func setSpan(_ id: UUID, _ span: Int) {
        guard let i = tiles.firstIndex(where: { $0.id == id }), tiles[i].span != span else { return }
        tiles[i].span = span
    }

    func reset() { tiles = Self.standard }
}

// MARK: - The grid

/// How many columns the board has at a width: 290 pt at least each, at most four.
enum PeekGrid {
    static let spacing: CGFloat = 18
    static let maxWidth: CGFloat = 1400

    static func columns(_ width: CGFloat) -> Int { max(1, min(4, Int((width + spacing) / (290 + spacing)))) }

    static func columnWidth(_ width: CGFloat) -> CGFloat {
        let n = CGFloat(columns(width))
        return (width - spacing * (n - 1)) / n
    }
}

struct PeekSpan: LayoutValueKey { static let defaultValue = 1 }

/// Tiles in columns, each in order where its columns are shortest, so tiles of different heights pack without gaps.
struct PeekMasonry: Layout {
    var spacing: CGFloat = PeekGrid.spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? PeekGrid.maxWidth
        let frames = arrange(width, subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(arrange(bounds.width, subviews), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let columns = PeekGrid.columns(width)
        let column = PeekGrid.columnWidth(width)
        var heights = [CGFloat](repeating: 0, count: columns)
        return subviews.map { subview in
            let span = min(max(subview[PeekSpan.self], 1), columns)
            var start = 0
            var top = CGFloat.infinity
            for c in 0...(columns - span) {
                let y = heights[c..<(c + span)].max() ?? 0
                if y < top - 0.5 { (start, top) = (c, y) }
            }
            let w = column * CGFloat(span) + spacing * CGFloat(span - 1)
            let h = subview.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            for c in start..<(start + span) { heights[c] = top + h + spacing }
            return CGRect(x: CGFloat(start) * (column + spacing), y: top, width: w, height: h)
        }
    }
}

struct PeekFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - The tiles' data

/// What the newer tiles show, loaded each time the board opens, only for the tiles on it. The last answers stay
/// while new ones come.
@MainActor
final class PeekData: ObservableObject {
    static let shared = PeekData()

    @Published var scores: HealthScores?
    @Published var habits: [Habit]?
    @Published var food: FoodDay?
    @Published var plan: ExamPlan?
    @Published var money: FinanceMonth?
    @Published var weather: DigestWeather?
    @Published var bedtime: BedtimeOverview?
    @Published var trams: NearbyBoards?

    func load(_ env: AppEnvironment, kinds: Set<PeekTileKind>) async {
        let api = env.api
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                group.addTask { @MainActor in
                    switch kind {
                    case .body: if let v = try? await api.healthScores() { self.scores = v }
                    case .habits: if let v = try? await api.habits() { self.habits = v }
                    case .food: if let v = try? await api.food() { self.food = v }
                    case .study: if let v = try? await api.examPlan() { self.plan = v }
                    case .money: if let v = try? await api.financeMonth() { self.money = v }
                    case .bedtime: if let v = try? await api.bedtime() { self.bedtime = v }
                    case .trams: if let v = try? await api.nearbyDepartures() { self.trams = v }
                    case .weather: if let v = await Self.weather(api) { self.weather = v }
                    case .week, .glance, .team, .waiting: break
                    }
                }
            }
        }
    }

    /// Weather has no endpoint of its own: the wake-up briefing's section (rebuilt on each read), else the morning's.
    private static func weather(_ api: APIClient) async -> DigestWeather? {
        for kind in ["wake", "daily"] {
            guard let digest = try? await api.digest(kind: kind) else { continue }
            for section in digest.sections { if case .weather(let w) = section.content { return w } }
        }
        return nil
    }

    func tick(_ habit: Habit, env: AppEnvironment) async {
        let new = habit.isLimit ? try? await env.api.countHabit(habit.id)
                                : try? await env.api.checkHabit(habit.id, done: !habit.doneToday)
        guard let new, let i = habits?.firstIndex(where: { $0.id == habit.id }) else { return }
        habits?[i] = new
    }
}

// MARK: - The newer tiles

private func eur(_ value: Double) -> String {
    value.formatted(.currency(code: "EUR").locale(Locale(identifier: "it_IT")).precision(.fractionLength(0)))
}

private func clock(_ iso: String?) -> String? {
    iso.flatMap(Wire.parse).map { $0.formatted(date: .omitted, time: .shortened) }
}

private struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tile's heading, and the whole heading a link to its section when it has one.
struct PeekTileHeading: View {
    let kind: PeekTileKind
    var detail: String? = nil
    let open: (MacSection) -> Void

    var body: some View {
        HStack(spacing: 6) {
            PanelHeading(kind.title)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if kind.section != nil {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture { if let section = kind.section { open(section) } }
    }
}

struct PeekBodyTile: View {
    let scores: HealthScores?
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekTileHeading(kind: .body, open: open)
            if let scores {
                HStack(spacing: 0) {
                    ring("Recovery", scores.recovery?.score, ScoreColors.recovery(scores.recovery?.score))
                    ring("Strain", scores.strain?.score, ScoreColors.strain)
                    ring("Sleep", scores.sleep?.score, ScoreColors.sleep)
                }
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }

    private func ring(_ label: String, _ value: Int?, _ colors: [Color]) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(value ?? 0) / 100)
                    .stroke(AngularGradient(colors: colors, center: .center), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\($0)" } ?? "–")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 58, height: 58)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PeekHabitsTile: View {
    let habits: [Habit]?
    let tick: (Habit) -> Void
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let list = habits ?? []
            let done = list.filter { !$0.isLimit && $0.doneToday }.count
            let goals = list.filter { !$0.isLimit }.count
            PeekTileHeading(kind: .habits, detail: goals == 0 ? nil : "\(done) of \(goals)", open: open)
            if let habits {
                if habits.isEmpty { Placeholder(text: "No habits yet") }
                ForEach(habits) { habit in row(habit) }
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }

    private func row(_ habit: Habit) -> some View {
        HStack(spacing: 10) {
            Button { tick(habit) } label: {
                if habit.isLimit {
                    Image(systemName: "plus.circle").font(.system(size: 17))
                } else {
                    Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(habit.doneToday ? PeekTileKind.habits.tint : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help(habit.isLimit ? "One more today" : habit.doneToday ? "Not done after all" : "Done today")
            Text(habit.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(habit.doneToday && !habit.isLimit ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if habit.isLimit {
                let count = habit.count ?? 0, max = habit.cadence.max ?? 0
                Text(max > 0 ? "\(count)/\(max)" : "\(count)")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(max > 0 && count > max ? .orange : .secondary)
            } else if habit.streak > 1 {
                Label("\(habit.streak)", systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct PeekFoodTile: View {
    let food: FoodDay?
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekTileHeading(kind: .food, detail: food?.score.map { "Score \($0.score)" }, open: open)
            if let food {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(food.totals.calories.formatted())
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(food.goals.calories.map { "of \($0.formatted()) kcal" } ?? "kcal")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if let goal = food.goals.calories, goal > 0 {
                        bar(Double(food.totals.calories) / Double(goal), PeekTileKind.food.tint)
                    }
                    HStack(spacing: 14) {
                        macro("Protein", food.totals.proteinG, food.goals.proteinG)
                        macro("Carbs", food.totals.carbsG, food.goals.carbsG)
                        macro("Fat", food.totals.fatG, food.goals.fatG)
                    }
                    Text(food.meals.isEmpty ? "No meals logged yet"
                         : food.meals.count == 1 ? "1 meal" : "\(food.meals.count) meals")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }

    private func macro(_ name: String, _ grams: Int, _ goal: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(goal.map { "\(grams)/\($0) g" } ?? "\(grams) g")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            if let goal, goal > 0 { bar(Double(grams) / Double(goal), .white.opacity(0.55)) }
            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PeekStudyTile: View {
    let plan: ExamPlan?
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let total = plan?.today.reduce(0) { $0 + $1.minutes } ?? 0
            PeekTileHeading(kind: .study, detail: total > 0 ? PlanTime.text(total) : nil, open: open)
            if let plan {
                if plan.today.isEmpty { Placeholder(text: "Nothing planned today") }
                ForEach(Array(plan.today.prefix(5).enumerated()), id: \.offset) { _, block in
                    let phase = PlanPhase.of(block.phase)
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(phase.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.topic?.title ?? block.name)
                                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(phase.title) · \(block.name)")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(PlanTime.text(block.minutes))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
                if let next = plan.targets.min(by: { $0.daysLeft < $1.daysLeft }) {
                    HStack(spacing: 6) {
                        Circle().fill(PlanStatus.color(next.status)).frame(width: 6, height: 6)
                        Text("\(next.name): \(next.what) \(next.daysLeft == 0 ? "today" : next.daysLeft == 1 ? "tomorrow" : "in \(next.daysLeft) days") · \(PlanStatus.word(next.status))")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }
}

struct PeekMoneyTile: View {
    let month: FinanceMonth?
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekTileHeading(kind: .money, detail: month.map { "\($0.daysLeft) days left" }, open: open)
            if let month {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(eur(month.spent))
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        if let budget = month.budget {
                            Text("of \(eur(budget))").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    if let budget = month.budget, budget > 0 {
                        bar(month.spent / budget, month.ahead ? .orange : PeekTileKind.money.tint)
                    }
                    Text(month.line)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let top = month.categories.sorted { $0.spent > $1.spent }.prefix(3)
                    let most = top.first?.spent ?? 1
                    ForEach(Array(top)) { category in
                        HStack(spacing: 8) {
                            Text(category.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .frame(width: 96, alignment: .leading)
                            bar(category.spent / max(most, 1), category.over ? .orange : .white.opacity(0.45))
                            Text(eur(category.spent)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }
}

struct PeekWeatherTile: View {
    let weather: DigestWeather?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekTileHeading(kind: .weather, detail: weather?.place, open: { _ in })
            if let weather {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: WeatherCard.icon(weather.now?.symbol ?? weather.symbol))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(weather.now.map { "\($0.temp)°" } ?? "\(weather.low)–\(weather.high)°")
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                            Text(weather.now.map { "\($0.words) · \(weather.low)–\(weather.high)°" } ?? weather.words)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text(weather.summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hours = weather.hours, !hours.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(hours.prefix(6)) { hour in
                                VStack(spacing: 4) {
                                    Text(clock(hour.at) ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Image(systemName: WeatherCard.icon(hour.symbol)).symbolRenderingMode(.multicolor)
                                        .font(.system(size: 14))
                                    Text("\(hour.temp)°").font(.system(size: 11, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }
}

struct PeekBedtimeTile: View {
    let bedtime: BedtimeOverview?
    let open: (MacSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekTileHeading(kind: .bedtime, open: open)
            if let plan = bedtime?.tonight {
                HStack(spacing: 12) {
                    LivePebble(mood: "sleeping", size: 34)
                        .foregroundStyle(PeekTileKind.bedtime.tint)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bed at \(clock(plan.bedtime) ?? "–")")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("\(hours(plan.needMin)) of sleep · up at \(clock(plan.wake) ?? "–")")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        if let event = plan.event {
                            Text("Early: \(event.title)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                Placeholder(text: bedtime == nil ? "Loading…" : "No plan for tonight")
            }
        }
    }

    private func hours(_ minutes: Int) -> String { "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }
}

struct PeekTramsTile: View {
    let trams: NearbyBoards?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeekTileHeading(kind: .trams, detail: trams?.fixAt.flatMap(Wire.parse).map { "near your phone, \($0.formatted(.relative(presentation: .named)))" },
                            open: { _ in })
            if let trams {
                if trams.boards.isEmpty { Placeholder(text: "No stops near your phone") }
                ForEach(trams.boards.prefix(2)) { board in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(board.stop.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let walk = board.walk {
                                Label("\(walk) min", systemImage: "figure.walk")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(board.lines.prefix(3)) { line in
                            HStack(spacing: 8) {
                                Text(line.line)
                                    .font(.system(size: 11, weight: .bold)).monospacedDigit()
                                    .frame(minWidth: 26).padding(.vertical, 2)
                                    .background(PeekTileKind.trams.tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(.black)
                                Text(line.towards ?? "").font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(minutes(line.arrivals))
                                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            } else {
                Placeholder(text: "Loading…")
            }
        }
    }

    private func minutes(_ arrivals: [DepartureBoard.Arrival]) -> String {
        let mins = arrivals.compactMap(\.date).filter { $0 > .now.addingTimeInterval(-30) }.prefix(2)
            .map { max(0, Int($0.timeIntervalSinceNow / 60)) }
        return mins.isEmpty ? "–" : mins.map { $0 == 0 ? "now" : "\($0)′" }.joined(separator: ", ")
    }
}

private func bar(_ fraction: Double, _ color: Color) -> some View {
    GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.08))
            Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
        }
    }
    .frame(height: 5)
}
