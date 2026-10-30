import SwiftUI

/// One agent's routines: jobs it runs on a schedule, each posting in its own chat (docs/API.md, "Routines").
/// Its watches come first: checks that speak up only when something needs you ("Watches").
/// Each says in a line what it does; switch them on and off here, tap one to change it, or start from an idea.
struct RoutinesSheet: View {
    @EnvironmentObject private var chat: ChatViewModel
    let agent: Agent
    /// "Open chat" or a finished "Run now": the caller opens it once the sheet is gone.
    let choose: (PastChatsSheet.Choice) -> Void

    private var ideas: [RoutineIdea] {
        let titles = Set(chat.routines(of: agent).map { $0.title.lowercased() })
        return agent.routineIdeas.filter { !titles.contains($0.title.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Jobs \(agent.name) does by itself at a set time. Watches check quietly and speak up only "
                         + "when something needs you; routines post every time.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    let watches = chat.routines(of: agent).filter(\.isWatch)
                    if !watches.isEmpty {
                        DetailCard("Watches", padding: 0) { rows(watches) }
                    }
                    let routines = chat.routines(of: agent).filter { !$0.isWatch }
                    DetailCard("Routines", padding: 0) {
                        if routines.isEmpty {
                            Text("Nothing yet. \(agent.name) can do something for you on a schedule and post it in its own chat.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            RowDivider(leading: 16)
                        }
                        rows(routines)
                        if !routines.isEmpty { RowDivider(leading: 60) }
                        NavigationLink {
                            RoutineEditor(agent: agent, choose: choose)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus").font(.body.weight(.semibold))
                                    .frame(width: 32, height: 32)
                                Text("New routine").font(.body.weight(.medium))
                                Spacer()
                            }
                            .foregroundStyle(tint)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPress())
                    }
                    if !ideas.isEmpty {
                        DetailCard("Ideas", note: "Tap one to look it over, then Save to turn it on.", padding: 0) {
                            ForEach(Array(ideas.enumerated()), id: \.element) { i, idea in
                                if i > 0 { RowDivider(leading: 60) }
                                NavigationLink {
                                    RoutineEditor(agent: agent, idea: idea, choose: choose)
                                } label: {
                                    RoutineLine(title: idea.title, blurb: idea.blurb, watch: idea.watch, tint: tint,
                                                when: Schedule.label(time: idea.time, days: idea.days)) {
                                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(tint)
                                    }
                                }
                                .buttonStyle(RowPress())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Theme.grouped)
            .navigationTitle("\(agent.name)'s routines")
            .navigationBarTitleDisplayMode(.inline)
            .task { await chat.loadRoutines() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.grouped)
    }

    private var tint: Color { agent.orchestrator ? Theme.slate : agent.tint }

    private func rows(_ routines: [Routine]) -> some View {
        ForEach(Array(routines.enumerated()), id: \.element.id) { i, routine in
            if i > 0 { RowDivider(leading: 60) }
            HStack(spacing: 0) {
                NavigationLink {
                    RoutineEditor(agent: agent, routine: routine, choose: choose)
                } label: {
                    RoutineLine(title: routine.title, blurb: routine.blurb, watch: routine.isWatch, tint: tint,
                                when: when(routine), on: routine.enabled) { EmptyView() }
                }
                .buttonStyle(RowPress())
                Toggle(routine.title, isOn: Binding(
                    get: { routine.enabled },
                    set: { on in Task { await chat.setEnabled(routine, on) } }))
                    .labelsHidden()
                    .tint(tint)
                    .padding(.trailing, 16)
            }
        }
    }

    /// "Weekdays at 11:00 · next Tomorrow 11:00", or "… · off".
    private func when(_ routine: Routine) -> String {
        let schedule = Schedule.label(time: routine.time, days: routine.days)
        guard routine.enabled else { return schedule + " · off" }
        guard let next = routine.nextRun.flatMap(Wire.parse) else { return schedule }
        let day = ActivityDays.upcoming(next)
        return schedule + " · next " + (Calendar.current.isDateInToday(next) ? "today \(day)" : day)
    }
}

/// A routine or an idea in a card: an eye or a clock, its name, what it does and when.
private struct RoutineLine<Trailing: View>: View {
    let title: String
    let blurb: String
    let watch: Bool
    let tint: Color
    let when: String
    var on = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: watch ? "eye" : "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? tint : .secondary)
                .frame(width: 32, height: 32)
                .background((on ? tint : Color.secondary).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(on ? .primary : .secondary)
                Text(blurb).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Make or change a routine: what it does, when, whether it posts every time, and what the agent is asked.
struct RoutineEditor: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let agent: Agent
    var routine: Routine?
    private let idea: RoutineIdea?
    let choose: (PastChatsSheet.Choice) -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var enabled: Bool
    @State private var watch: Bool
    @State private var isBusy = false
    @State private var error: String?
    /// After Run now on a watch that found nothing.
    @State private var quiet = false

    init(agent: Agent, routine: Routine? = nil, idea: RoutineIdea? = nil, choose: @escaping (PastChatsSheet.Choice) -> Void) {
        self.agent = agent
        self.routine = routine
        self.idea = idea
        self.choose = choose
        _title = State(initialValue: routine?.title ?? idea?.title ?? "")
        _prompt = State(initialValue: routine?.prompt ?? idea?.prompt ?? "")
        _time = State(initialValue: Self.date(from: routine?.time ?? idea?.time ?? "09:00"))
        _days = State(initialValue: Set(routine?.days ?? idea?.days ?? []))
        _enabled = State(initialValue: routine?.enabled ?? true)
        _watch = State(initialValue: routine?.isWatch ?? idea?.watch ?? false)
    }

    private var tint: Color { agent.orchestrator ? Theme.slate : agent.tint }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var blurb: String? { routine?.blurb ?? idea?.blurb }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedPrompt.isEmpty
    }

    var body: some View {
        Form {
            if let blurb {
                Section("What it does") {
                    Text(blurb).foregroundStyle(.secondary)
                }
                .listRowBackground(Theme.row)
            }
            Section("Name") {
                TextField("e.g. Weekly recap", text: $title)
            }
            .listRowBackground(Theme.row)
            Section {
                Toggle("On", isOn: $enabled).tint(tint)
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                DayPicker(days: $days, tint: tint)
            } header: {
                Text("When")
            } footer: {
                Text(Schedule.label(time: Self.string(from: time), days: days.sorted()) + ". No day picked means every day.")
            }
            .listRowBackground(Theme.row)
            Section {
                choice("Every time", detail: "Posts a note in its chat on every run.", picked: !watch) { watch = false }
                choice("Only when something needs you",
                       detail: "Checks quietly and posts only if there's something for you. It can't change anything on its own.",
                       picked: watch) { watch = true }
            } header: {
                Text("Posts")
            }
            .listRowBackground(Theme.row)
            Section {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should \(agent.name) do each time?")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 4)
                    }
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text("Instructions")
            } footer: {
                Text("What \(agent.name) is asked each run, with its tools and memory. You don't see this in the chat.")
            }
            .listRowBackground(Theme.row)
            if let routine {
                Section {
                    Button {
                        Task { await runNow(routine) }
                    } label: {
                        Label(routine.isWatch ? "Check now" : "Run now", systemImage: "play.fill")
                    }
                    if quiet {
                        Label("Nothing needs you right now.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let id = routine.conversationId {
                        Button { choose(.openID(id)) } label: { Label("Open its chat", systemImage: "bubble.left") }
                    }
                    Button("Delete routine", role: .destructive) {
                        Task { await chat.delete(routine); dismiss() }
                    }
                }
                .listRowBackground(Theme.row)
                .disabled(isBusy)
            }
            if let error {
                Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
            }
        }
        .tint(tint)
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(routine == nil ? "New routine" : routine!.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView() } else {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    /// One of two answers, with a tick on the picked one.
    private func choice(_ title: String, detail: String, picked: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(tint)
                    .opacity(picked ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        // The line for the app stays with the instructions it was written for: an idea's comes along, and
        // changing a routine's instructions clears it (the app then shows their first sentence).
        let summary: String? = if let routine {
            trimmedPrompt == routine.prompt ? nil : ""
        } else {
            trimmedPrompt == idea?.prompt ? idea?.summary : nil
        }
        let draft = RoutineDraft(agent: agent.id, title: title.trimmingCharacters(in: .whitespaces),
                                 prompt: trimmedPrompt, time: Self.string(from: time), days: days.sorted(),
                                 enabled: enabled, watch: watch, summary: summary)
        do {
            try await chat.save(draft, id: routine?.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runNow(_ routine: Routine) async {
        isBusy = true
        quiet = false
        defer { isBusy = false }
        do {
            if let id = try await chat.run(routine) { choose(.openID(id)) } else { quiet = true }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0,
                                     second: 0, of: Date()) ?? Date()
    }

    static func string(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
    }
}

/// Seven round day buttons, Monday first. None picked means every day.
struct DayPicker: View {
    @Binding var days: Set<Int>
    let tint: Color

    var body: some View {
        let names = DateFormatter() // its symbols start on Sunday
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(names.veryShortWeekdaySymbols[day % 7])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(on ? Theme.background : .primary)
                        .background(on ? tint : Theme.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names.weekdaySymbols[day % 7])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
