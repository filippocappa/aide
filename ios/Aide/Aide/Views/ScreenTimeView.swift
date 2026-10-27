import FamilyControls
import SwiftUI

/// Settings → Screen Time (docs/API.md, "Screen Time"): allow it, pick what stays open, lock now, and the weekly
/// locks. Coach sets them in chat too. Ending one early takes a reason and a short wait.
struct ScreenTimeView: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @State private var picking = false
    @State private var unlocking: ScreenLock?
    @State private var adding = false

    var body: some View {
        List {
            if let error = screenTime.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
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
                Button {
                    picking = true
                } label: {
                    LabeledContent("Stays open", value: screenTime.allowedCount == 0 ? "Nothing yet"
                                   : "\(screenTime.allowedCount) app\(screenTime.allowedCount == 1 ? "" : "s")")
                }
                .disabled(!screenTime.isAuthorized)
            } footer: {
                Text("Everything else is locked during a lock. Calls and emergency always work. Pick Aide too, so you "
                     + "can still end a lock early here, and anything you need on the way (Maps, your bank's app).")
            }
            Section {
                if let (lock, until) = screenTime.current {
                    LabeledContent {
                        Button("End early…") { unlocking = lock }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Locked until \(Self.time(until))")
                            Text(lock.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Menu {
                        ForEach([15, 30, 60, 120], id: \.self) { minutes in
                            Button(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes > 60 ? "s" : "")") {
                                Task { await screenTime.lockNow(minutes: minutes) }
                            }
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
                    NavigationLink { LockEditor(lock: lock) } label: { LockRow(lock: lock) }
                }
                ForEach(screenTime.locks.filter { $0.once && !$0.locked }) { lock in
                    LockRow(lock: lock)
                }
                Button("Add a lock") { adding = true }
            } header: {
                Text("Locks")
            } footer: {
                Text("Coach sets these in chat too: \"lock my phone from 23:00 to 7:00 on weeknights\", \"no phone until "
                     + "16:00\". They start and end on time with Aide closed.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Screen Time")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $picking, selection: $screenTime.allowed)
        .sheet(item: $unlocking) { lock in UnlockSheet(lock: lock) }
        .sheet(isPresented: $adding) { NavigationStack { LockEditor(lock: nil) } }
        .refreshable { await screenTime.sync() }
        .task { await screenTime.sync() }
    }

    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Title, when, and who set it, with a switch for a weekly lock.
private struct LockRow: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    let lock: ScreenLock

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lock.title)
                Text(lock.summary).font(.subheadline).foregroundStyle(.secondary)
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

    private var note: String? {
        var parts: [String] = []
        if lock.locked, let until = LockBook.date(lock.until) {
            parts.append("On now, until \(ScreenTimeView.time(until))")
        } else if let open = LockBook.date(lock.openUntil) {
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
    @State private var isBusy = false

    init(lock: ScreenLock?) {
        self.lock = lock
        _title = State(initialValue: lock?.title ?? "Bedtime")
        _start = State(initialValue: RoutineEditor.date(from: lock?.start ?? "23:00"))
        _end = State(initialValue: RoutineEditor.date(from: lock?.end ?? "07:00"))
        _days = State(initialValue: Set(lock?.days ?? []))
        _enabled = State(initialValue: lock?.enabled ?? true)
    }

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

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        if await screenTime.save(lock, title: title.trimmingCharacters(in: .whitespaces),
                                 start: RoutineEditor.string(from: start), end: RoutineEditor.string(from: end),
                                 days: days.sorted(), enabled: enabled) {
            dismiss()
        }
    }
}

/// Ending a lock early: say why, then wait a few seconds. Coach sees the reason.
private struct UnlockSheet: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    let lock: ScreenLock

    static let wait = 10
    @State private var reason = ""
    @State private var left = UnlockSheet.wait
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why now?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text(lock.once ? "It ends for good." : "It's back next time, as usual. Coach sees the reason.")
                }
                .listRowBackground(Theme.row)
                if let error = screenTime.lastError {
                    Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("End \(lock.title) early")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep it") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy { ProgressView() } else {
                        Button(left > 0 ? "Unlock (\(left))" : "Unlock") {
                            Task {
                                isBusy = true
                                if await screenTime.unlock(lock, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)) {
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
        .presentationDetents([.medium])
    }
}
