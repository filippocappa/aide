import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → This Mac → Screen Time (#30): the phone's locks (docs/API.md, "Screen Time"), with what they cover on
/// this Mac. Lock now (Strict switched on or off), the apps a lock usually covers, and the weekly locks, each with its
/// own apps if it wants. A lock made here holds on the phone too, over the phone's own apps. While a strict lock is
/// on, the page is locked: only an emergency pass is left, as on the phone.
struct MacScreenTimeView: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @State private var minutes = 60
    @State private var strict = false
    @State private var unlocking: Unlocking?
    @State private var editing: Editing?
    @State private var editingLimit: EditingLimit?

    struct Unlocking: Identifiable {
        let hold: MacHold
        let pass: Bool
        var id: String { hold.lock.map { "lock\($0.id)" } ?? "limit\(hold.limit?.id ?? 0)" }

        init(lock: ScreenLock, pass: Bool) { hold = MacHold(lock: lock, until: Date()); self.pass = pass }
        init(limit: ScreenLimit, pass: Bool) { hold = MacHold(limit: limit, until: Date()); self.pass = pass }
    }

    /// A limit to change, or a new one (nil).
    struct EditingLimit: Identifiable {
        let limit: ScreenLimit?
        var id: Int { limit?.id ?? 0 }
    }

    /// A lock to change, or a new one (nil).
    struct Editing: Identifiable {
        let lock: ScreenLock?
        var id: Int { lock?.id ?? 0 }
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
        .navigationTitle("Screen Time")
        .sheet(item: $unlocking) { item in MacUnlockSheet(hold: item.hold, pass: item.pass) }
        .sheet(item: $editingLimit) { item in
            NavigationStack {
                MacLimitEditor(limit: item.limit, apps: item.limit.flatMap { screenTime.limitApps[$0.id] } ?? [])
            }
        }
        .sheet(item: $editing) { item in
            NavigationStack {
                MacLockEditor(lock: item.lock, apps: item.lock.map { screenTime.lockApps[$0.id] } ?? nil)
            }
        }
        .task { await screenTime.sync() }
    }

    // MARK: A strict lock is on

    @ViewBuilder
    private func strictPage(_ lock: ScreenLock, until: Date) -> some View {
        Section {
            VStack(spacing: 10) {
                LivePebble(mood: "sleeping", size: 72).foregroundStyle(Theme.accent)
                Text("Locked until \(Self.time(until))").font(.title3.weight(.semibold))
                Text("\(lock.title) is strict: nothing here changes, and Aide won't quit, until it's over.")
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

    // MARK: The page

    @ViewBuilder
    private var page: some View {
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
                Picker("For", selection: $minutes) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { Text(Self.length($0)).tag($0) }
                }
                Toggle("Strict", isOn: $strict)
                Button {
                    Task { await screenTime.lockNow(minutes: minutes, strict: strict) }
                } label: {
                    Label(strict ? "Lock now, strict" : "Lock now", systemImage: strict ? "lock.shield" : "lock")
                }
                .disabled(screenTime.usualApps.isEmpty)
            }
        } header: {
            Text("Now")
        } footer: {
            if screenTime.current == nil {
                Text(strict ? "Strict: no Open anyway. It ends early only with an emergency pass "
                                + "(\(screenTime.passes?.month ?? 3) a month), and this page is locked until it's over."
                            : "Locks the usual apps below, on the phone too (its own apps there). Open anyway takes a "
                                + "reason and a 10 s wait.")
            }
        }
        Section {
            AppList(apps: screenTime.usualApps, locked: screenTime.usualInUse) { screenTime.setUsualApps($0) }
        } header: {
            Text("Usually locked")
        } footer: {
            Text(screenTime.usualInUse ? "A lock that uses these is on now: change them once it's over."
                 : "For Lock now and the locks Coach sets. Only these are closed, and a website's tab in Safari, "
                    + "Chrome, Arc, Brave or Edge; everything else stays open. Finder, System Settings and Aide never are.")
        }
        Section {
            ForEach(screenTime.locks.filter { !$0.once && $0.id >= 0 }) { lock in
                Button { editing = Editing(lock: lock) } label: { MacLockRow(lock: lock) }
                    .buttonStyle(.plain)
            }
            ForEach(screenTime.locks.filter { $0.once && !$0.locked && $0.id >= 0 }) { lock in
                MacLockRow(lock: lock)
            }
            Button { editing = Editing(lock: nil) } label: { Label("Add a lock", systemImage: "plus") }
        } header: {
            Text("Locks")
        } footer: {
            Text("The phone's locks: each holds on both, over the apps each picked. Coach sets these in chat too: "
                 + "\"no Mac or phone after 23:00\".")
        }
        Section {
            ForEach(screenTime.limits) { limit in
                Button { editingLimit = EditingLimit(limit: limit) } label: {
                    MacLimitRow(limit: limit) {
                        unlocking = Unlocking(limit: limit, pass: limit.strict)
                    }
                }
                .buttonStyle(.plain)
            }
            Button { editingLimit = EditingLimit(limit: nil) } label: { Label("Add a limit", systemImage: "plus") }
        } header: {
            Text("Daily limits")
        } footer: {
            Text("So many minutes a day in some apps, then they're closed until midnight. Each device counts its own "
                 + "time: here, this Mac's time in the apps picked here; on the phone, the phone's.")
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

/// Mac apps by bundle ID: each with its icon and name, − to take it out, and Add Apps… (the Applications folder).
private struct AppList: View {
    let apps: Set<String>
    var locked = false
    let set: (Set<String>) -> Void
    @State private var site = ""

    var body: some View {
        ForEach(MacApp.sorted(apps)) { app in
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                Text(app.name)
                Spacer()
                Button {
                    set(apps.subtracting([app.id]))
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Don't lock \(app.name)")
                .disabled(locked)
            }
        }
        Button { pick() } label: { Label("Add Apps…", systemImage: "plus") }
            .disabled(locked)
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 22)
            TextField("Add a website", text: $site, prompt: Text("Add a website, like youtube.com"))
                .textFieldStyle(.plain)
                .onSubmit(addSite)
            if MacBrowser.site(typed: site) != nil {
                Button("Add", action: addSite)
            }
        }
        .disabled(locked)
    }

    private func addSite() {
        guard let found = MacBrowser.site(typed: site) else { return }
        set(apps.union([MacSites.entry(found)]))
        site = ""
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.title = "Apps to lock"
        panel.prompt = "Lock"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { !MacLockApps.never.contains($0) }
        set(apps.union(picked))
    }
}

/// An app on this Mac, found from its bundle ID (one that's gone keeps its ID as the name).
private struct MacApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(_ id: String) {
        self.id = id
        if let site = MacSites.site(of: id) {
            name = site
            icon = NSImage(systemSymbolName: "globe", accessibilityDescription: site) ?? NSImage()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = id
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }

    static func sorted(_ ids: Set<String>) -> [MacApp] {
        ids.map(MacApp.init).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Title, when, what it covers here, and who set it, with a switch for a weekly lock.
private struct MacLockRow: View {
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
                    .disabled(lock.locked)
            }
        }
        .contentShape(Rectangle())
        .opacity(lock.enabled ? 1 : 0.6)
    }

    private var appsLine: String {
        let apps = MacApp.sorted(screenTime.apps(for: lock)).map(\.name)
        if apps.isEmpty { return "Locks nothing on this Mac" }
        let names = apps.count <= 3 ? apps.formatted(.list(type: .and)) : "\(apps.prefix(2).joined(separator: ", ")) and \(apps.count - 2) more"
        return "Locks " + names + (screenTime.lockApps[lock.id] == nil ? " (the usual)" : "")
    }

    private var note: String? {
        var parts: [String] = lock.isStrict ? ["Strict"] : []
        if lock.locked, let until = LockClock.date(lock.until) {
            parts.append("On now, until \(MacScreenTimeView.time(until))")
        } else if let open = LockClock.date(lock.openUntil) {
            parts.append("Ended early, back after \(MacScreenTimeView.time(open))")
        }
        if let agent = lock.agent { parts.append("Set by \(agent.prefix(1).uppercased() + agent.dropFirst())") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A weekly lock: its name, times, days, the Mac apps it covers, Strict. One that's on now can only be renamed (or
/// made strict).
private struct MacLockEditor: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let lock: ScreenLock?

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var days: Set<Int>
    @State private var enabled: Bool
    @State private var strict: Bool
    @State private var ownApps: Bool
    @State private var apps: Set<String>
    @State private var isBusy = false

    init(lock: ScreenLock?, apps: Set<String>?) {
        self.lock = lock
        _title = State(initialValue: lock?.title ?? "Bedtime")
        _start = State(initialValue: RoutineEditor.date(from: lock?.start ?? "23:00"))
        _end = State(initialValue: RoutineEditor.date(from: lock?.end ?? "07:00"))
        _days = State(initialValue: Set(lock?.days ?? []))
        _enabled = State(initialValue: lock?.enabled ?? true)
        _strict = State(initialValue: lock?.isStrict ?? false)
        _ownApps = State(initialValue: apps != nil)
        _apps = State(initialValue: apps ?? [])
    }

    private var on: Bool { lock?.locked == true }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title)
            }
            Section {
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
                DayPicker(days: $days, tint: Theme.accent)
                if lock != nil { Toggle("On", isOn: $enabled) }
            } footer: {
                Text(on ? "It's on now: change it once it's over, or end it early."
                     : "A \"to\" before the \"from\" is the next morning. The days are the ones it starts on; none "
                        + "picked is every day.")
            }
            .disabled(on)
            Section {
                Picker("On this Mac", selection: $ownApps) {
                    Text("The usual apps").tag(false)
                    Text("Its own apps").tag(true)
                }
                if ownApps {
                    AppList(apps: apps) { apps = $0 }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text(ownApps ? "Only these are closed on this Mac while it holds. The phone keeps its own pick."
                     : "The usual apps from the Screen Time page. The phone keeps its own pick.")
            }
            .disabled(on)
            Section {
                Toggle("Strict", isOn: $strict)
            } footer: {
                Text(on && lock?.isStrict == false
                     ? "It's on now: making it strict locks the Screen Time page until it's over."
                     : "No Open anyway: once it's on, it ends early only with an emergency pass (3 a month), not with "
                        + "a reason or through Coach, on the phone and here.")
            }
            .disabled(on && lock?.isStrict == true)
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
                .disabled(isBusy || on)
            }
            if let error = screenTime.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .macSheetTitle(lock?.title ?? "New lock")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView().controlSize(.small) } else {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        if await screenTime.save(lock, title: title.trimmingCharacters(in: .whitespaces),
                                 start: RoutineEditor.string(from: start), end: RoutineEditor.string(from: end),
                                 days: days.sorted(), enabled: enabled, strict: strict, apps: ownApps ? apps : nil) {
            dismiss()
        }
    }
}

/// Ending a lock or a limit early from the page: say why, then wait 10 s (a strict one: an emergency pass). Coach sees
/// the reason.
private struct MacUnlockSheet: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let hold: MacHold
    var pass = false

    @State private var reason = ""
    @State private var left = 10
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(pass ? "What's the emergency?" : "Why now?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text((pass ? "Uses one of your \(screenTime.passes?.left ?? 0) passes left this month. " : "")
                         + hold.afterUnlock + " Coach sees the reason.")
                }
                if let error = screenTime.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .macSheetTitle(pass ? "Emergency pass" : "End \(hold.title) early")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy { ProgressView().controlSize(.small) } else {
                        Button(left > 0 ? "Unlock (\(left))" : "Unlock") {
                            Task {
                                isBusy = true
                                if await screenTime.unlock(hold, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           pass: pass) {
                                    dismiss()
                                }
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
    }
}

/// A daily limit: its minutes and days, this Mac's time in its apps today, and whether it holds.
private struct MacLimitRow: View {
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
                    Text(note).font(.caption).foregroundStyle(screenTime.holds(limit) ? Theme.accent : .secondary)
                }
            }
            Spacer()
            if screenTime.holds(limit) {
                Button(limit.strict ? "Use a pass…" : "End early…", action: endEarly)
                    .disabled(limit.strict && screenTime.passes?.left == 0)
            } else {
                Toggle(limit.title, isOn: Binding(get: { limit.enabled },
                                                  set: { on in Task { await screenTime.setEnabled(limit, on) } }))
                    .labelsHidden()
            }
        }
        .contentShape(Rectangle())
        .opacity(limit.enabled ? 1 : 0.6)
    }

    private var appsLine: String {
        let apps = MacApp.sorted(screenTime.limitApps[limit.id] ?? []).map(\.name)
        if apps.isEmpty { return "No apps on this Mac yet: it counts only on the phone" }
        let names = apps.count <= 3 ? apps.formatted(.list(type: .and)) : "\(apps.prefix(2).joined(separator: ", ")) and \(apps.count - 2) more"
        return "Counts " + names
    }

    private var note: String? {
        var parts: [String] = limit.strict ? ["Strict"] : []
        if screenTime.holds(limit) {
            let at = screenTime.reachedHere(limit).map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            parts.append("Used up\(at), closed until midnight")
        } else if limit.openToday {
            parts.append("Ended early for today")
        } else if limit.enabled, limit.counts(on: Date()), screenTime.limitApps[limit.id] != nil {
            let used = Int(screenTime.usedToday(limit) / 60)
            parts.append("\(used) of \(limit.minutes) min today on this Mac")
        } else if limit.enabled, !limit.counts(on: Date()) {
            parts.append("Not today")
        }
        if limit.reachedToday, screenTime.reachedHere(limit) == nil, !limit.openToday {
            parts.append("Used up on the phone")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A daily limit: its name, minutes, days, the Mac apps it counts, Strict. A strict one used up today can only be
/// tightened (the server says no otherwise).
private struct MacLimitEditor: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let limit: ScreenLimit?

    @State private var title: String
    @State private var minutes: Int
    @State private var days: Set<Int>
    @State private var enabled: Bool
    @State private var strict: Bool
    @State private var apps: Set<String>
    @State private var isBusy = false

    private static let choices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360]

    init(limit: ScreenLimit?, apps: Set<String>) {
        self.limit = limit
        _title = State(initialValue: limit?.title ?? "Social")
        _minutes = State(initialValue: limit?.minutes ?? 30)
        _days = State(initialValue: Set(limit?.days ?? []))
        _enabled = State(initialValue: limit?.enabled ?? true)
        _strict = State(initialValue: limit?.strict ?? false)
        _apps = State(initialValue: apps)
    }

    private var held: Bool { limit.map { screenTime.holds($0) } ?? false }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title)
            }
            Section {
                Picker("A day", selection: $minutes) {
                    ForEach(Set(Self.choices + [minutes]).sorted(), id: \.self) { Text(MacScreenTimeView.length($0)).tag($0) }
                }
                DayPicker(days: $days, tint: Theme.accent)
                if limit != nil { Toggle("On", isOn: $enabled) }
            } footer: {
                Text("None of the days picked is every day. The same limit counts on the phone, over the phone's own apps.")
            }
            Section {
                AppList(apps: apps, locked: held) { apps = $0 }
            } header: {
                Text("Apps and websites on this Mac")
            } footer: {
                Text(held ? "Used up today: its apps change tomorrow, or end it early."
                     : "This Mac's time in these, added up (a website in any browser, in front or playing on the side). "
                        + "Once it reaches the limit the apps are closed and the website's tab too, until midnight.")
            }
            Section {
                Toggle("Strict", isOn: $strict)
            } footer: {
                Text("Once it's used up, it ends early only with an emergency pass (3 a month), and it can't be "
                     + "loosened or deleted until tomorrow.")
            }
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
                .disabled(isBusy)
            }
            if let error = screenTime.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .macSheetTitle(limit?.title ?? "New limit")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView().controlSize(.small) } else {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        if await screenTime.saveLimit(limit, title: title.trimmingCharacters(in: .whitespaces), minutes: minutes,
                                      days: days.sorted(), enabled: enabled, strict: strict, apps: apps) {
            dismiss()
        }
    }
}
