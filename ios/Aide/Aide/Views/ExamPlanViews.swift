import Charts
import SwiftUI

/// The exam plan in the app (docs/API.md, "Exam plan"): today's study on the Study tab, the plan's page (every
/// course's next exam, whether its hours fit the free days before it), a course's own page, and the daily caps.

/// The four kinds of work, as the plan names them.
enum PlanPhase: String, CaseIterable {
    case learn, practise, mocks, review

    var title: String {
        switch self {
        case .learn: "Learn"
        case .practise: "Practise"
        case .mocks: "Mock exams"
        case .review: "Review"
        }
    }

    var color: Color {
        switch self {
        case .learn: Theme.study
        case .practise: .blue
        case .mocks: .orange
        case .review: .teal
        }
    }

    var symbol: String {
        switch self {
        case .learn: "book"
        case .practise: "rectangle.on.rectangle.angled"
        case .mocks: "doc.text"
        case .review: "arrow.counterclockwise"
        }
    }

    static func of(_ name: String) -> PlanPhase { PlanPhase(rawValue: name) ?? .learn }
}

/// Minutes as the plan says them: "45 min", "2 h", "2 h 15", "31 h".
enum PlanTime {
    static func text(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) min" }
        if m >= 600 { return "\(Int((minutes / 60).rounded())) h" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", rest))"
    }

    /// Hours to one decimal below 10, else whole: "1.5 h", "31 h".
    static func hours(_ minutes: Double) -> String {
        let h = minutes / 60
        if h < 10 { return "\(h.formatted(.number.precision(.fractionLength(0...1)))) h" }
        return "\(Int(h.rounded())) h"
    }

    static func day(_ s: String) -> String { Wire.day(s).map(StudyDay.word) ?? s }
    static func shortDay(_ s: String) -> String {
        Wire.day(s).map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? s
    }
}

/// A target's status as a word and a colour.
enum PlanStatus {
    static func word(_ status: String) -> String {
        switch status {
        case "fits": "Fits"
        case "tight": "Tight"
        case "short": "Short"
        default: "No notes yet"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "fits": Theme.toggle
        case "tight": .orange
        case "short": .red
        default: .secondary
        }
    }

    /// "20 h of work, 104 h free before it." / "Short by 6 h: 40 h of work, 34 h free."
    static func sentence(_ t: PlanTarget) -> String {
        switch t.status {
        case "empty": return "No notes written yet, so nothing to count. The plan starts once the notebook has topics."
        case "short": return "Short by \(PlanTime.hours(t.shortMin)): \(PlanTime.hours(t.needMin)) of work, \(PlanTime.hours(t.freeMin)) free before it."
        case "tight": return "\(PlanTime.hours(t.needMin)) of work in \(PlanTime.hours(t.freeMin)) free: little room to spare."
        default: return "\(PlanTime.hours(t.needMin)) of work, \(PlanTime.hours(t.freeMin)) free before it."
        }
    }
}

struct PlanStatusPill: View {
    let status: String
    var body: some View {
        Text(PlanStatus.word(status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(PlanStatus.color(status))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(PlanStatus.color(status).opacity(0.14), in: Capsule())
    }
}

/// "2nd mid-term · Thu 3 Dec, 11:00 · in 26 days".
private func targetLine(_ t: PlanTarget) -> String {
    var day = PlanTime.day(t.date)
    if let time = t.time { day += ", \(time)" }
    let when = t.daysLeft == 0 ? "today" : t.daysLeft == 1 ? "tomorrow" : "in \(t.daysLeft) days"
    var parts = [t.what.prefix(1).uppercased() + t.what.dropFirst(), day]
    if t.daysLeft > 1 { parts.append(when) }
    if t.from == "expected" { parts.append("your guess") }
    return parts.joined(separator: " · ")
}

/// Pages pushed on the Study tab's stack.
struct ExamPlanPage: Hashable {}
struct StudyCapsPage: Hashable {}
struct PlanMocksPage: Hashable { let course: StudyCourse }

// MARK: - Today, on the Study tab

/// Today's study from the plan: a row per piece (the course, the phase, the topic, the minutes), each a tap from
/// doing it, and the way to the whole plan.
struct TodayPlanCard: View {
    let plan: ExamPlan
    let start: (PlanBlock) -> Void
    let focus: (PlanBlock) -> Void
    let open: () -> Void

    private var total: Double { plan.today.reduce(0) { $0 + $1.minutes } }
    private var worst: PlanTarget? {
        plan.targets.first { $0.status == "short" } ?? plan.targets.first { $0.status == "tight" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text((plan.today.isEmpty ? "Study plan" : "Today's plan · \(PlanTime.text(total))").uppercased())
                    .font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Button(action: open) {
                    HStack(spacing: 3) { Text("The plan"); Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.study)
                }
                .buttonStyle(.plain)
            }
            if plan.today.isEmpty {
                Text(plan.targets.isEmpty ? "No exam dates yet, so nothing to plan." : "Nothing planned for today.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(plan.today.enumerated()), id: \.offset) { _, block in
                Button { start(block) } label: { row(block) }
                    .buttonStyle(CardPress())
                    .contextMenu {
                        Button("Focus on it", systemImage: "timer") { focus(block) }
                    }
            }
            if let worst {
                Label("\(worst.title): \(PlanStatus.sentence(worst))", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(PlanStatus.color(worst.status))
                    .multilineTextAlignment(.leading)
            }
        }
        .card()
    }

    private func row(_ block: PlanBlock) -> some View {
        let phase = PlanPhase.of(block.phase)
        return HStack(spacing: 12) {
            Image(systemName: phase.symbol)
                .font(.body.weight(.semibold)).foregroundStyle(phase.color)
                .frame(width: 38, height: 38).background(phase.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(phase.title) · \(block.name.prefix(1).uppercased() + block.name.dropFirst())")
                    .font(.body.weight(.medium)).foregroundStyle(.primary)
                if let topic = block.topic {
                    Text(topic.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(PlanTime.text(block.minutes)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - The plan's page

/// Every course's next exam: whether its hours fit, the phases laid out to the date, what to watch; the courses with no
/// date; the daily caps.
struct ExamPlanView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var plan: ExamPlan?
    @State private var error: String?
    @State private var guessing: ExamPlan.Undated?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBlock("Exam plan") {
                    Text(subtitle).foregroundStyle(.secondary)
                }
                if let error { ErrorCard(text: error) }
                if let plan {
                    if plan.targets.isEmpty, plan.undated.isEmpty {
                        Text("No courses with notes or dates yet.").foregroundStyle(.secondary).card()
                    }
                    ForEach(plan.targets) { target in
                        NavigationLink(value: target) { PlanTargetCard(target: target) }
                            .buttonStyle(CardPress())
                    }
                    if !plan.undated.isEmpty { undatedCard(plan.undated) }
                    NavigationLink(value: StudyCapsPage()) { capsRow(plan.settings) }.buttonStyle(CardPress())
                } else if error == nil {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.row).frame(height: 150)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .pageGlow(Theme.study)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlanTarget.self) { target in
            PlanTargetView(target: target) { plan = $0 }.macPageBack()
        }
        .navigationDestination(for: StudyCapsPage.self) { _ in StudySettingsView().macPageBack() }
        .sheet(item: $guessing) { course in
            ExpectedDateSheet(course: course.course, name: course.name, date: nil) { plan = $0 }
        }
        .task { await load() }
        .refreshable { await load(fresh: true) }
    }

    private var subtitle: String {
        guard let plan else { return " " }
        let fit = plan.targets.filter { $0.status == "fits" }.count
        if plan.targets.isEmpty { return "Nothing dated to plan for" }
        if fit == plan.targets.count { return plan.targets.count == 1 ? "It fits" : "All \(plan.targets.count) fit" }
        return "\(fit) of \(plan.targets.count) fit"
    }

    private func undatedCard(_ courses: [ExamPlan.Undated]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NO DATE YET").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
            ForEach(courses, id: \.course) { course in
                HStack {
                    Text(course.name.prefix(1).uppercased() + course.name.dropFirst())
                    Spacer()
                    Chip(title: "Likely date", systemImage: "calendar") { guessing = course }
                }
            }
            Text("Without an exam date a course isn't planned. Give the date you expect; the real one replaces it when it comes.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card()
    }

    private func capsRow(_ s: StudySettings?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily limits").foregroundStyle(.primary)
                if let s {
                    Text("Up to \(PlanTime.text(Double(s.termCapMin))) a day in term, \(PlanTime.text(Double(s.seasonCapMin))) after the last lecture")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .card()
    }

    private func load(fresh: Bool = false) async {
        do {
            plan = try await env.api.examPlan(fresh: fresh)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A target in brief: the course, the date, the status, the phases as a strip, the first warning.
struct PlanTargetCard: View {
    let target: PlanTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(target.title).font(.headline).foregroundStyle(.primary)
                Spacer()
                PlanStatusPill(status: target.status)
            }
            Text(targetLine(target)).font(.subheadline).foregroundStyle(.secondary)
            if target.status != "empty" {
                PhaseStrip(target: target)
                Text(PlanStatus.sentence(target)).font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = target.warnings.first {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.leading)
        .card()
    }
}

/// The phases side by side, as wide as their hours, with the date each ends.
struct PhaseStrip: View {
    let target: PlanTarget
    private var phases: [PlanTarget.Phase] { target.phases.filter { $0.minutes > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = max(phases.reduce(0) { $0 + $1.minutes }, 1)
                let gaps = CGFloat(max(phases.count - 1, 0)) * 3
                HStack(spacing: 3) {
                    ForEach(phases, id: \.phase) { p in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(PlanPhase.of(p.phase).color)
                            .frame(width: max(6, (geo.size.width - gaps) * p.minutes / total))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(phases, id: \.phase) { p in
                    HStack(spacing: 4) {
                        Circle().fill(PlanPhase.of(p.phase).color).frame(width: 7, height: 7)
                        Text("\(PlanPhase.of(p.phase).title) \(PlanTime.hours(p.minutes))")
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

// MARK: - A course's plan

/// One exam's plan: the day-by-day hours by phase, the phases' dates, the warnings, the topics with what each still
/// needs, and the user's choices (a mid-term's topics, a likely date).
struct PlanTargetView: View {
    @State var target: PlanTarget
    var changed: (ExamPlan) -> Void = { _ in }
    @EnvironmentObject private var env: AppEnvironment
    @State private var picking = false
    @State private var guessing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBlock(target.title) {
                    Text(targetLine(target)).foregroundStyle(.secondary)
                    PlanStatusPill(status: target.status)
                }
                if let error { ErrorCard(text: error) }
                summaryCard
                if !target.days.isEmpty { daysCard }
                if !target.phases.isEmpty { phasesCard }
                if !target.warnings.isEmpty || target.fallback != nil || target.moved != nil { notesCard }
                if !target.topics.isEmpty { topicsCard }
                choicesCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .pageGlow(Theme.study)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $picking) {
            PlanTopicsSheet(target: target) { apply($0) }
        }
        .sheet(isPresented: $guessing) {
            ExpectedDateSheet(course: target.course, name: target.name, date: target.from == "expected" ? target.date : nil) {
                apply($0)
            }
        }
    }

    private func apply(_ plan: ExamPlan) {
        changed(plan)
        if let fresh = plan.targets.first(where: { $0.course == target.course }) { target = fresh }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PlanStatus.sentence(target)).multilineTextAlignment(.leading)
            if target.status != "empty" {
                GeometryReader { geo in
                    let free = max(target.freeMin, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.chip)
                        Capsule().fill(PlanStatus.color(target.status))
                            .frame(width: geo.size.width * min(target.needMin / free, 1))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 0) {
                    stat(PlanTime.hours(target.needMin), "to do")
                    stat(PlanTime.hours(target.freeMin), "free")
                    stat("\(target.daysLeft)", target.daysLeft == 1 ? "day" : "days")
                    if let mocks = target.mocks {
                        stat("\(mocks.taken)/\(mocks.count)", "mocks")
                    }
                }
            }
        }
        .card()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct DayPart: Identifiable {
        let date: Date
        let phase: PlanPhase
        let minutes: Double
        var id: String { "\(date.timeIntervalSince1970)-\(phase.rawValue)" }
    }

    private var parts: [DayPart] {
        target.days.flatMap { day -> [DayPart] in
            guard let date = Wire.day(day.date) else { return [] }
            return PlanPhase.allCases.compactMap { phase in
                (day.phases[phase.rawValue] ?? 0) > 0 ? DayPart(date: date, phase: phase, minutes: day.phases[phase.rawValue]!) : nil
            }
        }
    }

    private var daysCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DAY BY DAY").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
            Chart(parts) { part in
                BarMark(x: .value("Day", part.date, unit: .day), y: .value("Minutes", part.minutes))
                    .foregroundStyle(part.phase.color)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let m = value.as(Double.self) { Text(PlanTime.text(m)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, target.days.count / 5))) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 160)
            if let today = target.days.first, Wire.day(today.date).map(Calendar.current.isDateInToday) == true {
                Text("Today \(PlanTime.text(today.minutes)) for this course.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var phasesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PHASES").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
            ForEach(target.phases.filter { $0.minutes > 0 }, id: \.phase) { p in
                let phase = PlanPhase.of(p.phase)
                HStack(spacing: 12) {
                    Image(systemName: phase.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(phase.color)
                        .frame(width: 32, height: 32).background(phase.color.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase.title).font(.body.weight(.medium))
                        if let from = p.from, let to = p.to {
                            Text(from == to ? PlanTime.shortDay(from) : "\(PlanTime.shortDay(from)) – \(PlanTime.shortDay(to))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(PlanTime.hours(p.minutes)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        if let planned = p.planned, planned + 1 < p.minutes {
                            Text("\(PlanTime.hours(planned)) fits").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let mocks = target.mocks, mocks.count > 0 {
                Text("\(mocks.count) mock exams of \(PlanTime.text(mocks.minutesEach)) each, with going through them; \(mocks.taken) taken.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let stretch = target.stretch, stretch > 1.01, let left = target.lecturesLeft {
                Text("\(left) lectures still to come, so learning and practice are stretched by \(Int(((stretch - 1) * 100).rounded()))%.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(target.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let fallback = target.fallback {
                Label("If this one goes badly: \(fallback.what.lowercased()) \(StudyDay.phrase(Wire.day(fallback.date) ?? .now)), which \(fallback.fits ? "would fit" : "wouldn't fit either").",
                      systemImage: "arrow.uturn.forward")
                    .foregroundStyle(.secondary)
            }
            if let moved = target.moved, moved.minutes != 0 {
                Label("\(moved.minutes > 0 ? "Up" : "Down") \(PlanTime.hours(abs(moved.minutes))) since \(PlanTime.shortDay(moved.since))"
                      + ((moved.topics ?? 0) > 0 ? ", \(moved.topics!) more topics written" : "")
                      + ((moved.lectures ?? 0) > 0 ? ", \(moved.lectures!) more lectures" : "") + ".",
                      systemImage: moved.minutes > 0 ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.leading)
        .card()
    }

    private var topicsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TOPICS").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Text("learn · practise").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(target.topics) { topic in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title).font(.subheadline.weight(.medium))
                        Text(detail(topic)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(PlanTime.text(topic.learnMin)) · \(PlanTime.text(topic.practiseMin))")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
            }
        }
        .card()
    }

    private func detail(_ t: PlanTarget.Topic) -> String {
        var parts: [String] = []
        if let items = t.items, items > 0 { parts.append("\(t.known ?? 0) of \(items) known") }
        switch t.lesson {
        case "done": parts.append("lesson done")
        case "writing": parts.append("lesson being written")
        case .some(let step): parts.append("lesson \(step)")
        case nil: break
        }
        return parts.isEmpty ? "Not started" : parts.joined(separator: " · ")
    }

    private var choicesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if target.kind == "mid-term" {
                Button { picking = true } label: {
                    choice("Topics it covers", target.topicsChosen.map { "\($0.count) picked" } ?? "All", "checklist")
                }
                .buttonStyle(.plain)
            }
            if target.from == "expected" || target.from == "course" && target.dateId == nil {
                Button { guessing = true } label: { choice("Likely date", PlanTime.day(target.date), "calendar") }
                    .buttonStyle(.plain)
            }
        }
        .card()
        .opacity(target.kind == "mid-term" || target.from == "expected" ? 1 : 0)
        .frame(height: target.kind == "mid-term" || target.from == "expected" ? nil : 0)
    }

    private func choice(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.study).frame(width: 24)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Choices

/// A mid-term's topics: which ones it covers (none picked: all of them).
struct PlanTopicsSheet: View {
    let target: PlanTarget
    let done: (ExamPlan) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var all = true
    @State private var topics: [NotebookTopic] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Every topic", isOn: $all)
                } footer: {
                    Text("Pick the topics this mid-term covers, and only they are planned for it.")
                }
                if !all {
                    Section {
                        ForEach(topics.filter { $0.written == true }) { topic in
                            Button {
                                if picked.contains(topic.id) { picked.remove(topic.id) } else { picked.insert(topic.id) }
                            } label: {
                                HStack {
                                    Text(topic.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Spacer()
                                    if picked.contains(topic.id) { Image(systemName: "checkmark").foregroundStyle(Theme.study) }
                                }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            #if os(macOS)
            .toggleStyle(.phoneSwitch)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Topics it covers")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle("Topics it covers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(!all && picked.isEmpty)
                    }
                }
            }
            .task {
                if let chosen = target.topicsChosen { picked = Set(chosen); all = false }
                topics = (try? await env.api.notebook(course: target.course))?.topics ?? []
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let plan = try await env.api.changePlan(course: target.course,
                                                    PlanCourseChange(field: .topics(key: target.key, ids: all ? nil : Array(picked))))
            done(plan)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The date the user expects the exam on, for a course with none yet (or clearing it).
struct ExpectedDateSheet: View {
    let course: Int
    let name: String
    let date: String?
    let done: (ExamPlan) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var day = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Exam", selection: $day, in: Calendar.current.date(byAdding: .day, value: 1, to: .now)!...,
                               displayedComponents: .date)
                } footer: {
                    Text("The plan uses it until a real date comes from Esse3, the course's page or the Exam calendar.")
                }
                if date != nil {
                    Section { Button("Clear the date", role: .destructive) { Task { await save(nil) } } }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(name.prefix(1).uppercased() + name.dropFirst())
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle(name.prefix(1).uppercased() + name.dropFirst())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save(Wire.dayString(day)) } } }
                }
            }
            .onAppear { if let date, let d = Wire.day(date) { day = d } }
        }
        .presentationDetents([.medium])
    }

    private func save(_ value: String?) async {
        saving = true
        defer { saving = false }
        do {
            done(try await env.api.changePlan(course: course, PlanCourseChange(field: .expected(value))))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - The daily caps

/// Settings → Study: how much study a day the plan may ask for, in term and after the last lecture.
struct StudySettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var settings: StudySettings?
    @State private var error: String?
    @State private var save: Task<Void, Never>?

    var body: some View {
        Form {
            if let binding = Binding($settings) {
                Section {
                    cap("In term", binding.termCapMin)
                    cap("After the last lecture", binding.seasonCapMin)
                } footer: {
                    Text("The exam plan spreads each course's hours over the free time before its exam (from an hour after waking to bedtime, less the calendar), never more than this a day. Term ends with the timetable's last lecture.")
                }
            } else if error == nil {
                Section { Text("Loading…").foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Study")
        .task {
            do { settings = try await env.api.studySettings() } catch { self.error = error.localizedDescription }
        }
        .onChange(of: settings) { old, new in
            guard old != nil, let new else { return }
            save?.cancel()
            save = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                do { _ = try await env.api.setStudySettings(new); error = nil } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func cap(_ title: String, _ minutes: Binding<Int>) -> some View {
        Stepper(value: minutes, in: 15...600, step: 15) {
            LabeledContent(title, value: PlanTime.text(Double(minutes.wrappedValue)))
        }
    }
}
