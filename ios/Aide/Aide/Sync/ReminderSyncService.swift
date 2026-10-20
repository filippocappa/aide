import EventKit
import Foundation

struct ReminderList: Identifiable, Hashable {
    let id: String
    let title: String
}

/// What the phone looked like after the last successful sync, per EKReminder (keyed by external identifier).
/// Anything newer than this is a phone-side change; anything missing from the list was deleted.
struct SnapshotEntry: Codable, Equatable {
    var serverID: String
    var modifiedAt: Date
    /// Created from a server reminder: the server doesn't know its apple_id (or its list) yet.
    var needsReport: Bool
    /// The list it was in. Nil for entries from before every list synced.
    var list: String?
}

struct SyncState: Codable, Equatable {
    var cursor: String?
    /// Unused since every list syncs; kept so older saved state still decodes.
    var listID: String?
    var entries: [String: SnapshotEntry] = [:]
}

enum SyncError: LocalizedError {
    case noList, fetchFailed

    var errorDescription: String? {
        switch self {
        case .noList: "No Reminders list to sync. Make one in the Reminders app."
        case .fetchFailed: "Couldn't read Apple Reminders."
        }
    }
}

/// Mirrors the server's reminders into Apple Reminders, every list (docs/API.md, "Reminders"). Each reminder
/// carries its list by name; one without a list, or in a list the phone doesn't have, goes to the default list.
@MainActor
final class ReminderSyncService: ObservableObject {
    @Published private(set) var authorization: EKAuthorizationStatus
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lists: [ReminderList] = []

    private let store = EKEventStore()
    private let api: APIClient
    private let settings: AppSettings
    private var state: SyncState
    private var resyncRequested = false

    private static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminder-sync-state.json")
    }()

    init(api: APIClient, settings: AppSettings) {
        self.api = api
        self.settings = settings
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        state = (try? Data(contentsOf: Self.stateURL)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
            ?? SyncState()
        reloadLists()
    }

    var hasAccess: Bool { authorization == .fullAccess }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToReminders()
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        reloadLists()
    }

    func reloadLists() {
        guard hasAccess else { lists = []; return }
        lists = store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    // MARK: Sync

    /// Safe to call from anywhere, any time; overlapping calls fold into one extra pass.
    func sync() async {
        guard settings.isConfigured else { return }
        if authorization == .notDetermined { await requestAccess() }
        guard hasAccess else { return }
        if isSyncing { resyncRequested = true; return }

        isSyncing = true
        defer { isSyncing = false }

        var passes = 0
        repeat {
            resyncRequested = false
            passes += 1
            do {
                try await syncPass()
                lastError = nil
                lastSync = Date()
            } catch {
                lastError = error.localizedDescription
                return
            }
            // Reminders just created on the phone must report their apple_id back.
            if state.entries.values.contains(where: \.needsReport) { resyncRequested = true }
        } while resyncRequested && passes < 3
    }

    /// Ticks a reminder off on the phone, then syncs so the server hears about it.
    /// One that hasn't reached the phone yet gets there with a sync first. Returns whether it worked.
    @discardableResult
    func setCompleted(_ reminder: Reminder, _ done: Bool) async -> Bool {
        guard hasAccess else { return false }
        var found = localReminder(for: reminder)
        if found == nil { await sync(); found = localReminder(for: reminder) }
        guard let ek = found else { return false }
        ek.isCompleted = done
        do {
            try store.save(ek, commit: true)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        await sync()
        return true
    }

    private func localReminder(for reminder: Reminder) -> EKReminder? {
        let appleID = reminder.appleId ?? state.entries.first { $0.value.serverID == reminder.id }?.key
        return appleID.flatMap(findReminder)
    }

    private func syncPass() async throws {
        guard let fallback = resolveCalendar() else { throw SyncError.noList }
        let calendars = store.calendars(for: .reminder)

        let local = try await fetchReminders()
        var localByID: [String: EKReminder] = [:]
        for r in local {
            let ext: String? = r.calendarItemExternalIdentifier
            if let ext { localByID[ext] = r }
        }

        // Phone → server
        var changes: [ReminderChange] = []
        for (ext, r) in localByID {
            let entry = state.entries[ext]
            if entry == nil && r.isCompleted { continue } // don't import the lists' history
            let modified = r.lastModifiedDate ?? r.creationDate ?? Date()
            let edited = modified.timeIntervalSince(entry?.modifiedAt ?? .distantPast) > 0.5
            let moved = entry?.list != r.calendar?.title
            if let entry, !entry.needsReport, !edited, !moved { continue }
            var c = change(from: r, appleID: ext, serverID: entry?.serverID)
            // Moved to another list since the last sync: that's newer than anything the server has.
            if let entry, entry.list != nil, moved, !edited { c.modifiedAt = Wire.utc(Date()) }
            changes.append(c)
        }
        for (ext, entry) in state.entries where localByID[ext] == nil {
            changes.append(ReminderChange(
                id: entry.serverID, appleId: ext, title: "", notes: "", dueAt: nil,
                completed: false, modifiedAt: Wire.utc(Date()), deleted: true))
        }

        let response = try await api.syncReminders(cursor: state.cursor, changes: changes,
                                                   lists: calendars.map(\.title), defaultList: fallback.title)

        for c in changes where !c.deleted { state.entries[c.appleId]?.needsReport = false; state.entries[c.appleId]?.list = c.list }

        // Server → phone
        var touched: [(ek: EKReminder, serverID: String, serverAppleID: String?, serverList: String?)] = []
        for server in response.reminders {
            let known = server.appleId
                ?? state.entries.first(where: { $0.value.serverID == server.id })?.key
            var ek = known.flatMap { localByID[$0] ?? findReminder($0) }

            if server.deleted {
                if let ek { try store.remove(ek, commit: false) }
                state.entries = state.entries.filter { $0.value.serverID != server.id }
                continue
            }
            if ek == nil {
                if server.completed { continue } // don't resurrect finished history
                ek = EKReminder(eventStore: store)
            }
            guard let ek else { continue }
            let calendar = list(named: server.list, in: calendars) ?? fallback
            let moved = ek.calendar?.calendarIdentifier != calendar.calendarIdentifier
            if moved { ek.calendar = calendar }
            if apply(server, to: ek) || moved || ek.isNew { try store.save(ek, commit: false) }
            touched.append((ek, server.id, server.appleId, server.list))
        }
        try store.commit()

        // Record what the phone looks like now, so our own writes don't echo back as phone changes.
        for t in touched {
            let ext: String? = t.ek.calendarItemExternalIdentifier
            guard let ext else { continue }
            let list = t.ek.calendar?.title
            state.entries[ext] = SnapshotEntry(
                serverID: t.serverID, modifiedAt: t.ek.lastModifiedDate ?? Date(),
                needsReport: t.serverAppleID != ext || t.serverList != list, list: list)
        }
        state.cursor = response.cursor
        persist()
    }

    // MARK: EventKit helpers

    private func resolveCalendar() -> EKCalendar? {
        if !settings.reminderListID.isEmpty, let c = store.calendar(withIdentifier: settings.reminderListID) {
            return c
        }
        return store.defaultCalendarForNewReminders()
    }

    /// A list by name, any case, that can take reminders.
    private func list(named name: String?, in calendars: [EKCalendar]) -> EKCalendar? {
        guard let name else { return nil }
        return calendars.first { $0.allowsContentModifications && $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Every reminder in every list.
    private func fetchReminders() async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { cont in
            store.fetchReminders(matching: predicate) { result in
                if let result { cont.resume(returning: result) } else { cont.resume(throwing: SyncError.fetchFailed) }
            }
        }
    }

    private func findReminder(_ appleID: String) -> EKReminder? {
        store.calendarItems(withExternalIdentifier: appleID).compactMap { $0 as? EKReminder }.first
    }

    private func dueDate(of r: EKReminder) -> Date? {
        r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }

    private func change(from r: EKReminder, appleID: String, serverID: String?) -> ReminderChange {
        ReminderChange(
            id: serverID, appleId: appleID, title: r.title ?? "", notes: r.notes ?? "",
            dueAt: dueDate(of: r).map(Wire.local), completed: r.isCompleted,
            modifiedAt: Wire.utc(r.lastModifiedDate ?? Date()), deleted: false, list: r.calendar?.title)
    }

    /// Makes `r` match the server's version. Returns whether anything changed.
    private func apply(_ s: Reminder, to r: EKReminder) -> Bool {
        var changed = false
        if r.title != s.title { r.title = s.title; changed = true }
        if (r.notes ?? "") != s.notes { r.notes = s.notes.isEmpty ? nil : s.notes; changed = true }
        if r.isCompleted != s.completed { r.isCompleted = s.completed; changed = true }

        let due = s.dueDate
        let localDue = dueDate(of: r)
        let sameDue = (due == nil && localDue == nil)
            || (due != nil && localDue != nil && abs(due!.timeIntervalSince(localDue!)) < 1)
        if !sameDue {
            r.dueDateComponents = due.map {
                Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
            }
            changed = true
        }

        // One absolute alarm at the due time, so Apple notifies even with the app closed.
        // A date-only due (no time of day) the user set on the phone keeps no alarm.
        let dateOnly = sameDue && r.dueDateComponents != nil && r.dueDateComponents?.hour == nil
        let wantAlarm = due != nil && !s.completed && !dateOnly
        let absolute = (r.alarms ?? []).filter { $0.absoluteDate != nil }
        let alarmOK = wantAlarm
            ? absolute.count == 1 && abs(absolute[0].absoluteDate!.timeIntervalSince(due!)) < 1
            : absolute.isEmpty
        if !alarmOK {
            absolute.forEach(r.removeAlarm)
            if wantAlarm, let due { r.addAlarm(EKAlarm(absoluteDate: due)) }
            changed = true
        }
        return changed
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }
}
