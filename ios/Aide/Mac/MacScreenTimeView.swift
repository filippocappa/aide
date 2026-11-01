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

    struct Unlocking: Identifiable {
        let lock: ScreenLock
        let pass: Bool
        var id: Int { lock.id }
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
        .sheet(item: $unlocking) { item in MacUnlockSheet(lock: item.lock, pass: item.pass) }
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
                 : "For Lock now and the locks Coach sets. Only these are closed; everything else stays open. "
                    + "Finder, System Settings and Aide never are.")
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
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

/// Ending a lock early from the page: say why, then wait 10 s (a strict one: an emergency pass). Coach sees the reason.
private struct MacUnlockSheet: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let lock: ScreenLock
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
                         + (lock.once ? "It ends for good." : "It's back next time, as usual.") + " Coach sees the reason.")
                }
                if let error = screenTime.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .macSheetTitle(pass ? "Emergency pass" : "End \(lock.title) early")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy { ProgressView().controlSize(.small) } else {
                        Button(left > 0 ? "Unlock (\(left))" : "Unlock") {
                            Task {
                                isBusy = true
                                if await screenTime.unlock(lock, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
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
