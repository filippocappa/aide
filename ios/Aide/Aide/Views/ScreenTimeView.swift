import FamilyControls
import SwiftUI

/// Settings → Screen Time (docs/API.md, "Screen Time"): allow it, the apps a lock usually leaves open, lock now, and
/// the weekly locks, each with its own apps if it wants (everything but a few at bedtime, only social apps while
/// studying). Coach sets locks in chat too. Ending one early takes a reason and a short wait. While a strict lock is
/// on, the page is locked: only an emergency pass (3 a month) is left.
struct ScreenTimeView: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @State private var picking = false
    @State private var unlocking: Unlocking?
    @State private var adding = false

    @State private var countingPicker = false
    @State private var addingLimit = false
    @State private var unlockingLimit: ScreenLimit?

    /// The sheet that ends a lock early: with a reason, or for a strict one an emergency pass.
    struct Unlocking: Identifiable {
        let lock: ScreenLock
        let pass: Bool
        var id: Int { lock.id }
    }

    var body: some View {
        List {
            if let error = screenTime.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            if let (lock, until) = screenTime.strictOn {
                strictPage(lock, until: until)
            } else {
                page
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Screen Time")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $picking, selection: $screenTime.allowed)
        .sheet(item: $unlocking) { item in
            UnlockSheet(name: item.lock.title, pass: item.pass,
                        after: item.lock.once ? "It ends for good." : "It's back next time, as usual.") { reason in
                await screenTime.unlock(item.lock, reason: reason, pass: item.pass)
            }
        }
        .sheet(item: $unlockingLimit) { limit in
            UnlockSheet(name: limit.title, pass: limit.strict, after: "It counts again tomorrow.") { reason in
                await screenTime.unlock(limit, reason: reason, pass: limit.strict)
            }
        }
        .sheet(isPresented: $addingLimit) { NavigationStack { LimitEditor(limit: nil, apps: FamilyActivitySelection()) } }
        .familyActivityPicker(isPresented: $countingPicker, selection: $screenTime.counted)
        .sheet(isPresented: $adding) { NavigationStack { LockEditor(lock: nil, apps: LockApps(only: false, selection: screenTime.allowed)) } }
        .refreshable { await screenTime.sync() }
        .task { await screenTime.sync() }
    }

    /// A strict lock is on: nothing changes here until it's over, but for an emergency pass.
    @ViewBuilder
    private func strictPage(_ lock: ScreenLock, until: Date) -> some View {
        Section {
            VStack(spacing: 10) {
                Image("Pebble-sleeping").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("Locked until \(Self.time(until))").font(.title3.weight(.semibold))
                Text("\(lock.title) is strict: nothing here changes until it's over.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        let left = screenTime.passes?.left
        Section {
            Button {
                unlocking = Unlocking(lock: lock, pass: true)
            } label: {
                Label("Use an emergency pass", systemImage: "cross.case")
            }
            .disabled(left == 0)
        } header: {
            Text("Emergency")
        } footer: {
            Text(passesText(left))
        }
        if let used = screenTime.passes?.used, !used.isEmpty {
            Section("Used this month") {
                ForEach(used, id: \.self) { pass in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pass.reason)
                        Text("\(pass.title) · \(LockClock.date(pass.at).map { $0.formatted(.dateTime.day().month().hour().minute()) } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func passesText(_ left: Int?) -> String {
        guard let passes = screenTime.passes, let left else { return "An emergency pass ends it early." }
        let renews = (try? Date(passes.renews, strategy: .iso8601.year().month().day()))
            .map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? passes.renews
        if left == 0 { return "No passes left this month: they come back on \(renews)." }
        return "\(left) of \(passes.month) left this month (they come back on \(renews)). A pass ends this lock now; "
            + "Coach sees why."
    }

    @ViewBuilder
    private var page: some View {
        if !screenTime.isAuthorized {
            Section {
                Button("Allow Screen Time") { Task { await screenTime.authorize() } }
            } footer: {
                Text(screenTime.authorization == .denied
                     ? "Screen Time is off for Aide. Turn it on in iOS Settings → Screen Time → Apps with Screen Time Access."
                     : "Locks keep you off your phone when you've decided to be: \"no phone for an hour\", nothing "
                        + "after 23:00. iOS asks for Face ID or your passcode once.")
            }
        }
        Section {
            PickRow(title: "Stays open", value: screenTime.allowedCount == 0 ? "Nothing yet"
                    : "\(screenTime.allowedCount) app\(screenTime.allowedCount == 1 ? "" : "s")") { picking = true }
                .disabled(!screenTime.isAuthorized || screenTime.usualInUse)
        } header: {
            Text("Usually")
        } footer: {
            Text(screenTime.usualInUse ? "A lock that uses these is on now: change them once it's over."
                 : "For Lock now and the locks Coach sets: everything else is locked. Pick Aide too, so you can "
                    + "still end a lock early, and what you need on the way (Maps, your bank). Calls always work. "
                    + "Each lock can pick its own apps.")
        }
        Section {
            if let (lock, until) = screenTime.current {
                LabeledContent {
                    Button("End early…") { unlocking = Unlocking(lock: lock, pass: false) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Locked until \(Self.time(until))")
                        Text(lock.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                Menu {
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Button(Self.length(minutes)) { Task { await screenTime.lockNow(minutes: minutes) } }
                    }
                    Menu {
                        ForEach([30, 60, 120, 240], id: \.self) { minutes in
                            Button(Self.length(minutes)) { Task { await screenTime.lockNow(minutes: minutes, strict: true) } }
                        }
                    } label: {
                        Label("Strict", systemImage: "lock.shield")
                    }
                } label: {
                    Label("Lock now", systemImage: "lock")
                }
                .disabled(!screenTime.isAuthorized)
            }
        } header: {
            Text("Now")
        }
        Section {
            ForEach(screenTime.locks.filter { !$0.once }) { lock in
                NavigationLink { LockEditor(lock: lock, apps: screenTime.apps(for: lock)).macPageBack() } label: { LockRow(lock: lock) }
            }
            ForEach(screenTime.locks.filter { $0.once && !$0.locked }) { lock in
                LockRow(lock: lock)
            }
            Button { adding = true } label: { Label("Add a lock", systemImage: "plus") }
                .disabled(!screenTime.isAuthorized)
        } header: {
            Text("Locks")
        } footer: {
            Text("Coach sets these in chat too: \"lock my phone from 23:00 to 7:00 on weeknights\", \"no phone until "
                 + "16:00\". They start and end on time with Aide closed. A strict one ends early only with an "
                 + "emergency pass (\(screenTime.passes?.month ?? 3) a month), and locks this page while it's on.")
        }
        Section {
            ForEach(screenTime.limits) { limit in
                NavigationLink {
                    LimitEditor(limit: limit, apps: screenTime.limitApps[limit.id] ?? FamilyActivitySelection()).macPageBack()
                } label: {
                    LimitRow(limit: limit) { unlockingLimit = limit }
                }
            }
            Button { addingLimit = true } label: { Label("Add a limit", systemImage: "plus") }
                .disabled(!screenTime.isAuthorized)
        } header: {
            Text("Daily limits")
        } footer: {
            Text("Some apps get so much time a day, then they lock until midnight: Social, 30 minutes. Ending one "
                 + "early for the day takes a reason (a strict one, an emergency pass). Coach sees them.")
        }
        Section {
            PickRow(title: "Counted", value: screenTime.countedCount == 0 ? "Nothing yet"
                    : "\(screenTime.countedCount) categor\(screenTime.countedCount == 1 ? "y" : "ies")") { countingPicker = true }
                .disabled(!screenTime.isAuthorized)
        } header: {
            Text("Share with Coach")
        } footer: {
            Text("Pick every category (the top row in the picker) and Aide sends Coach how long you were on your "
                 + "phone each day, to the nearest 15 minutes. Which apps stays on this phone.")
        }
    }

    static func length(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes > 60 ? "s" : "")"
    }

    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A row that opens something: its value and a chevron, so it reads as tappable.
private struct PickRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

/// Title, when, which apps, and who set it, with a switch for a weekly lock.
private struct LockRow: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    let lock: ScreenLock

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lock.title)
                Text(lock.summary).font(.subheadline).foregroundStyle(.secondary)
                Text(appsLine).font(.caption).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !lock.once {
                Toggle(lock.title, isOn: Binding(get: { lock.enabled },
                                                 set: { on in Task { await screenTime.setEnabled(lock, on) } }))
                    .labelsHidden()
                    .tint(Theme.toggle)
                    .disabled(lock.locked)
            }
        }
        .opacity(lock.enabled ? 1 : 0.6)
    }

    /// "Locks everything but 3 apps", "Locks 4 apps".
    private var appsLine: String {
        let text = screenTime.apps(for: lock).text
        return text == "Nothing picked" ? "Locks nothing yet: pick its apps" : "Locks " + text.prefix(1).lowercased() + text.dropFirst()
    }

    private var note: String? {
        var parts: [String] = lock.isStrict ? ["Strict"] : []
        if lock.locked, let until = LockClock.date(lock.until) {
            parts.append("On now, until \(ScreenTimeView.time(until))")
        } else if let open = LockClock.date(lock.openUntil) {
            parts.append("Ended early, back after \(ScreenTimeView.time(open))")
        }
        if let agent = lock.agent { parts.append("Set by \(agent.prefix(1).uppercased() + agent.dropFirst())") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A weekly lock: its name, times and days. One that's on now can only be renamed.
private struct LockEditor: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let lock: ScreenLock?

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var days: Set<Int>
    @State private var enabled: Bool
    @State private var strict: Bool
    @State private var isBusy = false
    /// Lock only `blocked`, or everything but `kept`. Each mode keeps its own pick, so switching loses nothing.
    @State private var only: Bool
    @State private var kept: FamilyActivitySelection
    @State private var blocked: FamilyActivitySelection
    @State private var picking = false

    init(lock: ScreenLock?, apps: LockApps) {
        self.lock = lock
        _title = State(initialValue: lock?.title ?? "Bedtime")
        _start = State(initialValue: RoutineEditor.date(from: lock?.start ?? "23:00"))
        _end = State(initialValue: RoutineEditor.date(from: lock?.end ?? "07:00"))
        _days = State(initialValue: Set(lock?.days ?? []))
        _enabled = State(initialValue: lock?.enabled ?? true)
        _strict = State(initialValue: lock?.isStrict ?? false)
        _only = State(initialValue: apps.only)
        _kept = State(initialValue: apps.only ? LockBook.allowed : apps.selection)
        _blocked = State(initialValue: apps.only ? apps.selection : FamilyActivitySelection())
    }

    private var apps: LockApps { LockApps(only: only, selection: only ? blocked : kept) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title)
            }
            .listRowBackground(Theme.row)
            Section {
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
                DayPicker(days: $days, tint: Theme.accent)
                if lock != nil { Toggle("On", isOn: $enabled).tint(Theme.toggle) }
            } footer: {
                Text(lock?.locked == true ? "It's on now: change it once it's over, or end it early."
                     : "A \"to\" before the \"from\" is the next morning. The days are the ones it starts on; none "
                        + "picked is every day.")
            }
            .listRowBackground(Theme.row)
            .disabled(lock?.locked == true)
            Section {
                Picker("Lock", selection: $only) {
                    Text("Everything except…").tag(false)
                    Text("Only some apps").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                PickRow(title: only ? "Apps to lock" : "Stays open", value: appsValue) { picking = true }
            } header: {
                Text("Apps")
            } footer: {
                Text(only ? (blocked == FamilyActivitySelection() ? "Pick what to lock: nothing is locked until you do."
                             : "Only these are locked; everything else stays open. Picking a category (Social) "
                                + "covers apps you install later too.")
                     : "Everything else is locked. Pick Aide too, so you can still end the lock early. Calls always "
                        + "work. Pick single apps here: a whole category can't be kept open.")
            }
            .listRowBackground(Theme.row)
            .disabled(lock?.locked == true)
            Section {
                Toggle("Strict", isOn: $strict).tint(Theme.toggle)
            } footer: {
                Text(lock?.locked == true && lock?.isStrict == false
                     ? "It's on now: making it strict locks this page until it's over."
                     : "Once it's on, it ends early only with an emergency pass (3 a month), not with a reason or "
                        + "through Coach, and this page is locked until it's over.")
            }
            .listRowBackground(Theme.row)
            .disabled(lock?.locked == true && lock?.isStrict == true)
            if let lock {
                Section {
                    Button("Delete lock", role: .destructive) {
                        Task {
                            isBusy = true
                            if await screenTime.delete(lock) { dismiss() }
                            isBusy = false
                        }
                    }
                }
                .listRowBackground(Theme.row)
                .disabled(isBusy || lock.locked)
            }
            if let error = screenTime.lastError {
                Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .familyActivityPicker(isPresented: $picking, selection: only ? $blocked : $kept)
        .navigationTitle(lock?.title ?? "New lock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if lock == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView() } else {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var appsValue: String {
        let text = apps.text
        return only ? text : text == "Everything" ? "Nothing" : text.replacingOccurrences(of: "Everything but ", with: "")
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        if await screenTime.save(lock, title: title.trimmingCharacters(in: .whitespaces),
                                 start: RoutineEditor.string(from: start), end: RoutineEditor.string(from: end),
                                 days: days.sorted(), enabled: enabled, strict: strict, apps: apps) {
            dismiss()
        }
    }
}

/// Ending a lock or a limit early: say why, then wait a few seconds. Coach sees the reason.
private struct UnlockSheet: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let name: String
    /// An emergency pass, for a strict one.
    var pass = false
    /// What happens after: "It ends for good."
    let after: String
    let unlock: (String) async -> Bool

    static let wait = 10
    @State private var reason = ""
    @State private var left = UnlockSheet.wait
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(pass ? "What's the emergency?" : "Why now?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text((pass ? "Uses one of your \(screenTime.passes?.left ?? 0) passes left this month. " : "")
                         + after + " Coach sees the reason.")
                }
                .listRowBackground(Theme.row)
                if let error = screenTime.lastError {
                    Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(pass ? "Emergency pass" : "End \(name) early")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep it") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy { ProgressView() } else {
                        Button(left > 0 ? "Unlock (\(left))" : "Unlock") {
                            Task {
                                isBusy = true
                                if await unlock(reason.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                                isBusy = false
                            }
                        }
                        .disabled(left > 0 || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .task {
                while left > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    left -= 1
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A limit: its title, how much a day, and today: reached at 14:20 (with End for today), ended early, or not today.
private struct LimitRow: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    let limit: ScreenLimit
    let endEarly: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.title)
                Text(limit.summary).font(.subheadline).foregroundStyle(.secondary)
                Text(appsLine).font(.caption).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if screenTime.holds(limit) {
                Button(limit.strict ? "Pass…" : "End…", action: endEarly)
                    .buttonStyle(.bordered)
                    .disabled(limit.strict && screenTime.passes?.left == 0)
            } else {
                Toggle(limit.title, isOn: Binding(get: { limit.enabled },
                                                  set: { on in Task { await screenTime.setEnabled(limit, on) } }))
                    .labelsHidden()
                    .tint(Theme.toggle)
            }
        }
        .opacity(limit.enabled ? 1 : 0.6)
    }

    private var appsLine: String {
        let picked = screenTime.limitApps[limit.id] ?? FamilyActivitySelection()
        let text = LockApps(only: true, selection: picked).text
        return text == "Nothing picked" ? "No apps on this phone yet: pick them" : "Counts " + text
    }

    private var note: String? {
        var parts: [String] = limit.strict ? ["Strict"] : []
        if screenTime.holds(limit) {
            let at = screenTime.reachedAt(limit).map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            parts.append("Reached\(at), locked until midnight")
        } else if screenTime.reachedAt(limit) != nil {
            parts.append("Ended early for today")
        } else if limit.enabled && !limit.counts() {
            parts.append("Not today")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A daily limit: its name, how much a day, the days, the apps, strict. A strict one reached today can only be
/// tightened until tomorrow.
private struct LimitEditor: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let limit: ScreenLimit?

    @State private var title: String
    @State private var minutes: Int
    @State private var days: Set<Int>
    @State private var enabled: Bool
    @State private var strict: Bool
    @State private var apps: FamilyActivitySelection
    @State private var picking = false
    @State private var isBusy = false

    static let choices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    init(limit: ScreenLimit?, apps: FamilyActivitySelection) {
        self.limit = limit
        _title = State(initialValue: limit?.title ?? "Social")
        _minutes = State(initialValue: limit?.minutes ?? 30)
        _days = State(initialValue: Set(limit?.days ?? []))
        _enabled = State(initialValue: limit?.enabled ?? true)
        _strict = State(initialValue: limit?.strict ?? false)
        _apps = State(initialValue: apps)
    }

    /// Strict and used up today: nothing that loosens it until tomorrow.
    private var held: Bool { limit.map { $0.strict && screenTime.holds($0) } ?? false }

    private var amounts: [Int] {
        let all = Set(Self.choices + [minutes])
        return all.filter { !held || $0 <= (limit?.minutes ?? 0) }.sorted()
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title)
            } footer: {
                Text("Aide's server and Coach see this name, not the apps.")
            }
            .listRowBackground(Theme.row)
            Section {
                Picker("A day", selection: $minutes) {
                    ForEach(amounts, id: \.self) { m in Text(Self.amount(m)).tag(m) }
                }
                DayPicker(days: $days, tint: Theme.accent)
                    .disabled(held)
                if limit != nil { Toggle("On", isOn: $enabled).tint(Theme.toggle).disabled(held) }
            } footer: {
                Text(held ? "It's strict and used up today: it can only get tighter until tomorrow."
                     : "The days it counts on; none picked is every day. Time used earlier today counts too.")
            }
            .listRowBackground(Theme.row)
            Section {
                PickRow(title: "Apps", value: appsValue) { picking = true }
                    .disabled(held)
            } footer: {
                Text("Their time is added up; once it reaches the limit, they all lock until midnight. Picking a "
                     + "category (Social) covers apps you install later too.")
            }
            .listRowBackground(Theme.row)
            Section {
                Toggle("Strict", isOn: $strict).tint(Theme.toggle).disabled(held)
            } footer: {
                Text("Once it's used up, it ends early only with an emergency pass (3 a month), and can't be "
                     + "loosened until the next day.")
            }
            .listRowBackground(Theme.row)
            if let limit {
                Section {
                    Button("Delete limit", role: .destructive) {
                        Task {
                            isBusy = true
                            if await screenTime.delete(limit) { dismiss() }
                            isBusy = false
                        }
                    }
                }
                .listRowBackground(Theme.row)
                .disabled(isBusy || held)
            }
            if let error = screenTime.lastError {
                Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .familyActivityPicker(isPresented: $picking, selection: $apps)
        .navigationTitle(limit?.title ?? "New limit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if limit == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView() } else {
                    Button("Save") {
                        Task {
                            isBusy = true
                            if await screenTime.saveLimit(limit, title: title.trimmingCharacters(in: .whitespaces),
                                                          minutes: minutes, days: days.sorted(), enabled: enabled,
                                                          strict: strict, apps: apps) {
                                dismiss()
                            }
                            isBusy = false
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || apps == FamilyActivitySelection())
                }
            }
        }
    }

    private var appsValue: String {
        let text = LockApps(only: true, selection: apps).text
        return text == "Nothing picked" ? "Pick" : text
    }

    /// "30 min", "1 h 30 min".
    static func amount(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return [h > 0 ? "\(h) h" : nil, m > 0 ? "\(m) min" : nil].compactMap { $0 }.joined(separator: " ")
    }
}
