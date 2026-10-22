import SwiftUI

/// One agent's routines: jobs it runs on a schedule, each posting in its own chat (docs/API.md, "Routines").
/// Its watches come first: checks that speak up only when something needs you ("Watches").
/// Switch them on and off here, tap one to change it, or start from one of the agent's ideas.
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
            List {
                let watches = chat.routines(of: agent).filter(\.isWatch)
                if !watches.isEmpty {
                    Section {
                        rows(watches)
                    } header: {
                        Text("Keeps an eye on")
                    } footer: {
                        Text("\(agent.name) checks at these times and speaks up only when something needs you.")
                    }
                }
                Section {
                    let routines = chat.routines(of: agent).filter { !$0.isWatch }
                    if routines.isEmpty {
                        Text("Nothing yet. \(agent.name) can do something for you on a schedule and post it in its own chat.")
                            .foregroundStyle(.secondary)
                    }
                    rows(routines)
                    NavigationLink {
                        RoutineEditor(agent: agent, choose: choose)
                    } label: {
                        Label("New routine", systemImage: "plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(agent.tint)
                    }
                    .listRowBackground(Theme.row)
                }
                if !ideas.isEmpty {
                    Section("Ideas") {
                        ForEach(ideas, id: \.self) { idea in
                            NavigationLink {
                                RoutineEditor(agent: agent, idea: idea, choose: choose)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label {
                                        Text(idea.title)
                                    } icon: {
                                        if idea.watch { Image(systemName: "eye").foregroundStyle(agent.tint) }
                                    }
                                    .labelStyle(.titleAndIcon)
                                    Text(idea.watch ? "Only when something needs you · "
                                         + Schedule.label(time: idea.time, days: idea.days)
                                         : Schedule.label(time: idea.time, days: idea.days))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .listRowBackground(Theme.row)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("\(agent.name)'s routines")
            .navigationBarTitleDisplayMode(.inline)
            .task { await chat.loadRoutines() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.grouped)
    }

    private func rows(_ routines: [Routine]) -> some View {
        ForEach(routines) { routine in
            NavigationLink {
                RoutineEditor(agent: agent, routine: routine, choose: choose)
            } label: {
                RoutineRow(routine: routine, tint: agent.tint)
            }
            .listRowBackground(Theme.row)
        }
        .onDelete { offsets in
            let doomed = offsets.map { routines[$0] }
            Task { for r in doomed { await chat.delete(r) } }
        }
    }
}

/// A routine: what it's called, when it runs, and a switch.
private struct RoutineRow: View {
    @EnvironmentObject private var chat: ChatViewModel
    let routine: Routine
    let tint: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.title)
                Text(Schedule.label(time: routine.time, days: routine.days))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(routine.title, isOn: Binding(
                get: { routine.enabled },
                set: { on in Task { await chat.setEnabled(routine, on) } }))
                .labelsHidden()
                .tint(tint)
        }
    }
}

/// Make or change a routine: its name, what the agent should do, the time and the days.
struct RoutineEditor: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let agent: Agent
    var routine: Routine?
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
        self.choose = choose
        _title = State(initialValue: routine?.title ?? idea?.title ?? "")
        _prompt = State(initialValue: routine?.prompt ?? idea?.prompt ?? "")
        _time = State(initialValue: Self.date(from: routine?.time ?? idea?.time ?? "09:00"))
        _days = State(initialValue: Set(routine?.days ?? idea?.days ?? []))
        _enabled = State(initialValue: routine?.enabled ?? true)
        _watch = State(initialValue: routine?.isWatch ?? idea?.watch ?? false)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Weekly recap", text: $title)
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
            }
            .listRowBackground(Theme.row)
            Section {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                DayPicker(days: $days, tint: agent.tint)
                Toggle("On", isOn: $enabled).tint(agent.tint)
                Toggle("Only when something needs you", isOn: $watch).tint(agent.tint)
            } footer: {
                Text(Schedule.label(time: Self.string(from: time), days: days.sorted())
                     + (watch ? ". \(agent.name) checks then and posts only if something needs you; it can't change "
                        + "anything on its own." : "."))
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

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        let draft = RoutineDraft(agent: agent.id, title: title.trimmingCharacters(in: .whitespaces),
                                 prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                 time: Self.string(from: time), days: days.sorted(), enabled: enabled, watch: watch)
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
