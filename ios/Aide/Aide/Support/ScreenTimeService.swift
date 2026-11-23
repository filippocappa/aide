import DeviceActivity
import FamilyControls
import Foundation

/// Screen Time locks (docs/API.md, "Screen Time"). The server keeps the locks; this sets them on the phone: one
/// DeviceActivity schedule per lock, so the monitor extension shields and opens the apps on time with the app
/// closed, and the shield straight away for a lock that's already on. It syncs when the app opens, after a chat
/// turn and on a silent `sync` push. App lists ("App lists") are picked here once each and used by any lock, limit
/// or ration; a ration ("Rations") keeps its apps shielded but for the opens its shield offers (LockAction).
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published private(set) var authorization: AuthorizationStatus
    @Published private(set) var locks: [ScreenLock] = LockBook.locks
    /// The apps and sites that stay open in a lock without its own apps (Lock now, the ones Coach sets).
    @Published var allowed: FamilyActivitySelection = LockBook.allowed {
        didSet {
            LockBook.allowed = allowed
            Task { await report() }
        }
    }
    /// The apps and sites that stay open in a focus session's rounds. Changing them reshields a round that's on.
    @Published var focusAllowed: FamilyActivitySelection = LockBook.focusAllowed {
        didSet {
            LockBook.focusAllowed = focusAllowed
            apply()
        }
    }
    /// Apps and sites nothing ever locks here (Messages, Phone). Changing them reshields what holds now.
    @Published var alwaysOpen: FamilyActivitySelection = LockBook.alwaysOpen {
        didSet {
            LockBook.alwaysOpen = alwaysOpen
            apply()
        }
    }
    var alwaysOpenCount: Int { alwaysOpen.applicationTokens.count + alwaysOpen.webDomainTokens.count }

    /// The apps each lock picked for itself.
    @Published private(set) var apps: [Int: LockApps] = LockBook.apps
    @Published private(set) var lastError: String?
    @Published private(set) var passes: EmergencyPasses?
    /// Coach's line over the Screen half (what holds now or comes next), from the last sync.
    @Published private(set) var line: String?
    /// Daily app limits (docs/API.md, "Daily app limits") and the apps each counts.
    @Published private(set) var limits: [ScreenLimit] = LockBook.limits
    @Published private(set) var limitApps: [Int: FamilyActivitySelection] = LockBook.limitApps
    /// App lists, and this phone's pick of each.
    @Published private(set) var lists: [ScreenList] = LockBook.lists
    @Published private(set) var listApps: [Int: FamilyActivitySelection] = LockBook.listApps
    /// Rations, and the apps of each without a list.
    @Published private(set) var rations: [ScreenRation] = LockBook.rations
    @Published private(set) var rationApps: [Int: FamilyActivitySelection] = LockBook.rationApps
    /// What the estimate for Coach counts (every category, picked once).
    @Published var counted: FamilyActivitySelection = LockBook.counted {
        didSet {
            LockBook.counted = counted
            var scheduled = LockBook.scheduled
            scheduled[LockBook.usageActivity.rawValue] = nil // restart it with the new pick
            LockBook.scheduled = scheduled
            apply()
        }
    }

    private let api: APIClient
    private let center = DeviceActivityCenter()

    init(api: APIClient) {
        self.api = api
        authorization = AuthorizationCenter.shared.authorizationStatus
    }

    var isAuthorized: Bool { authorization == .approved }
    var allowedCount: Int { allowed.applicationTokens.count + allowed.webDomainTokens.count }

    /// The lock on now that ends last.
    var current: (lock: ScreenLock, until: Date)? {
        locks.compactMap { lock in LockClock.until(lock).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// A strict lock on now: the Screen Time page is locked until it ends, but for an emergency pass.
    var strictOn: (lock: ScreenLock, until: Date)? {
        locks.filter(\.isStrict).compactMap { lock in LockClock.until(lock).map { (lock, $0) } }.max { $0.1 < $1.1 }
    }

    /// A focus round is on: its apps can't change until it's over.
    var focusInUse: Bool { locks.contains { $0.focus != nil && LockClock.until($0) != nil } }
    /// A lock on now uses the usual apps: they can't change until it's over (that would be unlocking early).
    var usualInUse: Bool {
        locks.contains { $0.focus == nil && apps[$0.id] == nil && $0.list == nil && LockClock.until($0) != nil }
    }

    func apps(for lock: ScreenLock) -> LockApps {
        if lock.focus != nil { return LockApps(only: false, selection: LockBook.focusAllowed) }
        if let list = lock.list { return LockApps(only: true, selection: listApps[list] ?? FamilyActivitySelection()) }
        return apps[lock.id] ?? LockApps(only: false, selection: allowed)
    }

    /// This phone's pick of a list, nil when it hasn't picked it (or no list).
    func listPick(_ id: Int?) -> FamilyActivitySelection? {
        guard let id, let picked = listApps[id], picked != FamilyActivitySelection() else { return nil }
        return picked
    }

    func list(_ id: Int?) -> ScreenList? { id.flatMap { id in lists.first { $0.id == id } } }

    /// A lock or a limit using the list holds now: the list can't go.
    func listInUse(_ id: Int) -> Bool {
        locks.contains { $0.list == id && LockClock.until($0) != nil } || limits.contains { $0.list == id && holds($0) }
    }

    /// A strict lock or limit using the list holds now: its apps can be added to, not taken out (that would be
    /// unlocking it early, which takes a pass). Any other can be unlocked with a reason, so its list can change.
    func listHeldStrictly(_ id: Int) -> Bool {
        locks.contains { $0.list == id && $0.isStrict && LockClock.until($0) != nil }
            || limits.contains { $0.list == id && $0.strict && holds($0) }
    }

    /// What uses the list: "Bedtime, 23:00–08:00", the limits' and rations' titles.
    func listUsers(_ id: Int) -> [String] {
        locks.filter { $0.list == id }.map { lock in
            if let start = lock.start, let end = lock.end { return "\(lock.title), \(start)–\(end)" }
            return lock.title
        } + limits.filter { $0.list == id }.map(\.title) + rations.filter { $0.list == id }.map(\.title)
    }

    /// What a limit counts here.
    func limitPick(_ limit: ScreenLimit) -> FamilyActivitySelection {
        limit.list.map { listApps[$0] ?? FamilyActivitySelection() } ?? limitApps[limit.id] ?? FamilyActivitySelection()
    }

    func rationPick(_ ration: ScreenRation) -> FamilyActivitySelection {
        ration.list.map { listApps[$0] ?? FamilyActivitySelection() } ?? rationApps[ration.id] ?? FamilyActivitySelection()
    }

    func opensLeft(_ ration: ScreenRation) -> Int { LockBook.opensLeft(ration) }
    func rationOpenNow(_ ration: ScreenRation) -> Bool { LockBook.rationInUse(ration.id) }

    var focusAllowedCount: Int {
        let picked = LockBook.focusAllowed
        return picked.applicationTokens.count + picked.webDomainTokens.count
    }

    /// A lock's own apps, or nil for the usual ones. Not for a lock that's on.
    private func setApps(_ picked: LockApps?, for id: Int) {
        let usual = LockApps(only: false, selection: allowed)
        apps[id] = picked == usual ? nil : picked
        LockBook.apps = apps
    }

    /// iOS asks once (Face ID or the passcode); after a no, only iOS Settings → Screen Time can change it.
    func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        authorization = AuthorizationCenter.shared.authorizationStatus
        apply()
        await report()
    }

    var countedCount: Int { counted.categoryTokens.count + counted.applicationTokens.count }

    /// A limit holds now: reached today, its apps locked until midnight.
    func holds(_ limit: ScreenLimit) -> Bool { LockBook.limitHolds(limit) }

    /// When the phone saw it reached today.
    func reachedAt(_ limit: ScreenLimit) -> Date? {
        guard let hit = LockBook.limitHits[limit.id], hit.date == LockBook.day() else { return nil }
        return LockClock.date(hit.at)
    }

    /// The server's locks and limits, set on the phone, after sending what the monitor saw.
    func sync() async {
        authorization = AuthorizationCenter.shared.authorizationStatus
        await upload()
        do {
            let list = try await api.locks()
            locks = list.locks
            LockBook.locks = list.locks
            passes = list.passes
            line = list.line
            if let got = list.lists {
                lists = got
                LockBook.lists = got
                let known = Set(got.map(\.id))
                if listApps.keys.contains(where: { !known.contains($0) }) {
                    listApps = listApps.filter { known.contains($0.key) }
                    LockBook.listApps = listApps
                }
            }
            if let got = list.rations {
                // Gone (deleted on the server): open what it shielded.
                let kept = Set(got.map(\.id))
                for old in rations where !kept.contains(old.id) {
                    LockBook.openRationStore(old.id)
                    DeviceActivityCenter().stopMonitoring([LockBook.rationActivity(old.id)])
                }
                // The opens sent before this read are in the server's count now.
                var opens = LockBook.rationOpens
                for i in opens.indices where opens[i].sent { opens[i].counted = true }
                LockBook.rationOpens = opens
                rations = got
                LockBook.rations = got
                rationApps = rationApps.filter { kept.contains($0.key) }
                LockBook.rationApps = rationApps
            }
            if let got = list.limits {
                limits = got
                LockBook.limits = got
                // Ended early today on another device (or before a reinstall): don't lock it again today.
                var opened = LockBook.limitOpened
                for limit in got where limit.openToday { opened[limit.id] = LockBook.day() }
                LockBook.limitOpened = opened.filter { $0.value >= LockBook.day(Date().addingTimeInterval(-86400)) }
            }
            lastError = nil
            if list.device.authorized != isAuthorized || list.device.allowedApps != allowedCount { await report() }
        } catch APIError.server(404, _) {
            return // an older server, without locks
        } catch {
            lastError = error.localizedDescription
        }
        apply()
        await watchNudges()
    }

    /// The nudges' activities (`applyNudges`), the ones no longer wanted stopped.
    private func watchNudges() async {
        guard isAuthorized else { return }
        var scheduled = LockBook.scheduled
        var wanted = Set<DeviceActivityName>()
        await applyNudges(&scheduled, &wanted)
        for name in center.activities where NudgeBook.isNudge(name.rawValue) && !wanted.contains(name) {
            center.stopMonitoring([name])
        }
        for key in Array(scheduled.keys) where NudgeBook.isNudge(key) && !wanted.contains(DeviceActivityName(key)) {
            scheduled[key] = nil
        }
        LockBook.scheduled = scheduled
    }

    /// The last 7 days' usage steps and today's limits reached, to the server (Coach reads them).
    private func upload() async {
        let since = LockBook.day(Date().addingTimeInterval(-7 * 86400))
        let days = LockBook.usage.filter { $0.key >= since }.sorted { $0.key < $1.key }
            .map { UsageUpload.Day(date: $0.key, minutes: $0.value) }
        let hits = LockBook.limitHits.filter { $0.value.date >= since }
            .map { UsageUpload.Hit(id: $0.key, date: $0.value.date, at: $0.value.at) }
        if !days.isEmpty || !hits.isEmpty { try? await api.uploadUsage(UsageUpload(days: days, limits: hits)) }
        await sendNudges()
        // Opens LockAction couldn't send.
        for open in LockBook.rationOpens where !open.sent {
            do {
                try await api.openRation(open.ration, RationOpenBody(key: open.key, device: "phone", at: open.at, granted: true))
            } catch APIError.server(404, _) {
                // The ration is gone: nothing to count.
            } catch {
                continue
            }
            var opens = LockBook.rationOpens
            if let i = opens.firstIndex(where: { $0.key == open.key }) { opens[i].sent = true }
            LockBook.rationOpens = opens
        }
    }

    /// The nudges shown and answered on this phone, to the server, in order; what fails waits for the next sync.
    func sendNudges() async {
        for nudge in NudgeBook.pending {
            do {
                try await api.logNudge(NudgeLog(key: nudge.key, device: "phone", kind: nudge.kind, step: nudge.step,
                                                at: nudge.at, night: nudge.night, event: nudge.event,
                                                eventStart: nudge.eventStart, eventEnd: nudge.eventEnd,
                                                courseId: nudge.courseID, answer: nudge.answer))
            } catch APIError.server(let code, _) where code == 404 || code == 422 {
                // An older server, or one it won't take: dropped.
            } catch {
                return
            }
            NudgeBook.pending.removeAll { $0 == nudge }
        }
    }

    /// Tonight's bedtime steps and the next focus events watched (#84): the bedtime activity on anything counted,
    /// one per focus event (at most 3) on the Work list's apps. Restarted only when they change.
    private func applyNudges(_ scheduled: inout [String: String], _ wanted: inout Set<DeviceActivityName>) async {
        guard let plan = try? await api.nudges() else {
            // Unreachable: what's watched stays (a 404, an older server, ends with it).
            for name in center.activities where NudgeBook.isNudge(name.rawValue) { wanted.insert(name) }
            return
        }
        let now = Date()
        if let bed = plan.bedtime {
            let steps = bed.steps.compactMap { step -> NudgeBook.Step? in
                guard let at = LockClock.date(step.at), let until = LockClock.date(step.until) else { return nil }
                return NudgeBook.Step(step: step.step, at: at, until: until, title: step.title, body: step.body)
            }
            NudgeBook.night = NudgeBook.Night(date: bed.date, steps: steps)
            let name = NudgeBook.bedtimeActivity
            if counted != FamilyActivitySelection(), let first = steps.first, let last = steps.last,
               let schedule = NudgeBook.schedule(first.at, last.until, now: now) {
                wanted.insert(name)
                let key = "\(bed.date)-\(bed.bedtime)"
                if scheduled[name.rawValue] != key || !center.activities.contains(name) {
                    let events = Dictionary(uniqueKeysWithValues: NudgeBook.useSteps.map {
                        (NudgeBook.useEvent($0), NudgeBook.use(counted, minutes: $0))
                    })
                    do {
                        try center.startMonitoring(name, during: schedule, events: events)
                        scheduled[name.rawValue] = key
                    } catch {
                        lastError = "Couldn't set the bedtime nudges: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            NudgeBook.night = nil
        }
        let timed = plan.events.compactMap { event -> (NudgeEvent, Date, Date)? in
            guard let start = LockClock.date(event.start), let end = LockClock.date(event.end), end > now else { return nil }
            return (event, start, end)
        }
        NudgeBook.others = timed.filter { $0.0.kind == "other" }.map { DateInterval(start: $0.1, end: max($0.2, $0.1)) }
        let pick = plan.list.flatMap { listApps[$0.id] } ?? FamilyActivitySelection()
        var watches: [NudgeBook.Watch] = []
        if pick != FamilyActivitySelection() {
            for (i, (event, start, end)) in timed.filter({ $0.0.kind != "other" }).prefix(3).enumerated() {
                let name = NudgeBook.watchActivity(i)
                guard let schedule = NudgeBook.schedule(start, end, now: now) else { continue }
                watches.append(NudgeBook.Watch(activity: name.rawValue, title: event.title, start: start, end: end,
                                               startISO: event.start, endISO: event.end, courseID: event.course?.id))
                wanted.insert(name)
                let key = "\(event.start)-\(event.end)-\(event.title)-\(plan.list?.id ?? 0)-\(pick.applicationTokens.count).\(pick.categoryTokens.count).\(pick.webDomainTokens.count)"
                guard scheduled[name.rawValue] != key || !center.activities.contains(name) else { continue }
                do {
                    try center.startMonitoring(name, during: schedule, events: [
                        NudgeBook.first: NudgeBook.use(pick, minutes: 1),
                        NudgeBook.again: NudgeBook.use(pick, minutes: NudgeBook.againMinutes),
                    ])
                    scheduled[name.rawValue] = key
                } catch {
                    lastError = "Couldn't watch '\(event.title)': \(error.localizedDescription)"
                }
            }
        }
        NudgeBook.watches = watches
    }

    /// Each lock's schedule watched (restarted only when it changed), the ones gone stopped, and the shields set
    /// for what holds right now; the same for the limits, and the usage estimate.
    private func apply() {
        guard isAuthorized else { return }
        var scheduled = LockBook.scheduled
        var wanted = Set<DeviceActivityName>()
        applyLimits(&scheduled, &wanted)
        for lock in locks {
            let name = LockBook.activity(lock.id)
            guard let schedule = LockBook.schedule(for: lock) else { continue }
            wanted.insert(name)
            let key = "\(lock.start ?? "")-\(lock.end ?? "")-\(lock.startsAt ?? "")-\(lock.endsAt ?? "")"
            guard scheduled[name.rawValue] != key || !center.activities.contains(name) else { continue }
            do {
                try center.startMonitoring(name, during: schedule)
                scheduled[name.rawValue] = key
            } catch {
                lastError = "Couldn't set '\(lock.title)': \(error.localizedDescription)"
            }
        }
        for name in center.activities where !wanted.contains(name)
            && (LockBook.id(of: name) != nil || LockBook.limitID(of: name.rawValue) != nil || name == LockBook.usageActivity) {
            center.stopMonitoring([name])
        }
        // A lock that's gone from the server (deleted, ended early, over) opens if it had shielded anything.
        let known = Set(locks.map(\.id))
        for key in Array(scheduled.keys) where !wanted.contains(DeviceActivityName(key)) && !NudgeBook.isNudge(key) {
            scheduled[key] = nil
            if let id = LockBook.id(of: DeviceActivityName(key)), !known.contains(id) { LockBook.open(id) }
            if let id = LockBook.limitID(of: key) { LockBook.openLimit(id) } // deleted, turned off, no apps
        }
        LockBook.scheduled = scheduled
        if apps.keys.contains(where: { !known.contains($0) }) {
            apps = apps.filter { known.contains($0.key) }
            LockBook.apps = apps
        }
        for lock in locks {
            if LockClock.until(lock) != nil { LockBook.shield(lock.id) } else { LockBook.open(lock.id) }
        }
        for ration in rations {
            if LockBook.rationHolds(ration) {
                LockBook.shieldRation(ration)
            } else if !LockBook.rationInUse(ration.id) {
                LockBook.openRationStore(ration.id) // off, or no apps
            }
        }
        LockBook.applyFocusFilter()
    }

    /// A daily activity per limit with its apps (one threshold event), restarted when its minutes or apps change;
    /// the shields for what holds now. And the usage estimate's activity, once something is counted.
    private func applyLimits(_ scheduled: inout [String: String], _ wanted: inout Set<DeviceActivityName>) {
        for limit in limits {
            let name = LockBook.limitActivity(limit.id)
            let picked = limitPick(limit)
            guard limit.enabled, picked != FamilyActivitySelection() else { continue }
            wanted.insert(name)
            let key = "\(limit.minutes)-\(limit.list ?? 0)"
            if scheduled[name.rawValue] != key || !center.activities.contains(name) {
                do {
                    try center.startMonitoring(name, during: LockBook.wholeDay,
                                               events: [LockBook.limitEvent(limit.id): LockBook.event(picked, minutes: limit.minutes)])
                    scheduled[name.rawValue] = key
                } catch {
                    lastError = "Couldn't set the limit '\(limit.title)': \(error.localizedDescription)"
                }
            }
            if LockBook.limitHolds(limit) { LockBook.shieldLimit(limit.id) } else { LockBook.openLimit(limit.id) }
        }
        let usage = LockBook.usageActivity
        guard counted != FamilyActivitySelection() else { return }
        wanted.insert(usage)
        guard scheduled[usage.rawValue] == nil || !center.activities.contains(usage) else { return }
        let events = Dictionary(uniqueKeysWithValues: LockBook.usageSteps.map {
            (LockBook.usageEvent($0), LockBook.event(counted, minutes: $0))
        })
        do {
            try center.startMonitoring(usage, during: LockBook.wholeDay, events: events)
            scheduled[usage.rawValue] = "on"
        } catch {
            lastError = "Couldn't start counting screen time: \(error.localizedDescription)"
        }
    }

    /// So the agents can say when a lock won't hold.
    func report() async {
        try? await api.reportScreenTime(ScreenTimeDevice(authorized: isAuthorized, allowedApps: allowedCount))
    }

    // MARK: Changes from the app

    func lockNow(minutes: Int, strict: Bool = false, list: Int? = nil) async {
        await change {
            _ = try await self.api.createLock(NewLock(title: strict ? "Strict focus" : self.list(list)?.name ?? "Focus",
                                                      minutes: minutes, strict: strict ? true : nil, list: list))
        }
    }

    /// A lock that's on keeps its times, list and apps: only its title changes, or it becomes strict. With a list,
    /// the list's apps; else `picked`.
    func save(_ lock: ScreenLock?, title: String, start: String, end: String, days: [Int], enabled: Bool,
              strict: Bool, list: Int?, apps picked: LockApps) async -> Bool {
        await change {
            if let lock {
                let on = lock.locked
                let listChange = on || list == lock.list ? nil : (list ?? 0)
                _ = try await self.api.updateLock(lock.id, LockPatch(title: title, start: on ? nil : start,
                                                                     end: on ? nil : end, days: on ? nil : days,
                                                                     enabled: on ? nil : enabled,
                                                                     strict: on && !strict ? nil : strict,
                                                                     list: listChange))
                if !on && list == nil { self.setApps(picked, for: lock.id) }
            } else {
                let made = try await self.api.createLock(NewLock(title: title, start: start, end: end, days: days,
                                                                 strict: strict ? true : nil, list: list))
                if list == nil { self.setApps(picked, for: made.id) }
            }
        }
    }

    func setEnabled(_ lock: ScreenLock, _ on: Bool) async {
        await change { _ = try await self.api.updateLock(lock.id, LockPatch(enabled: on)) }
    }

    func unlock(_ lock: ScreenLock, reason: String, pass: Bool = false) async -> Bool {
        let done = await change { _ = try await self.api.unlock(lock.id, reason: reason, pass: pass) }
        if done { LockBook.open(lock.id) } // sync already did, unless the server was slow to say so
        return done
    }

    func delete(_ lock: ScreenLock) async -> Bool {
        await change { try await self.api.deleteLock(lock.id) }
    }

    // MARK: Limits from the app

    /// A limit's apps live only here. Changing them restarts its activity.
    private func setLimitApps(_ picked: FamilyActivitySelection, for id: Int) {
        limitApps[id] = picked
        LockBook.limitApps = limitApps
        var scheduled = LockBook.scheduled
        scheduled[LockBook.limitActivity(id).rawValue] = nil
        LockBook.scheduled = scheduled
    }

    func saveLimit(_ limit: ScreenLimit?, title: String, minutes: Int, days: [Int], enabled: Bool, strict: Bool,
                   list: Int?, apps picked: FamilyActivitySelection) async -> Bool {
        await change {
            if let limit {
                _ = try await self.api.updateLimit(limit.id, LimitPatch(title: title, minutes: minutes, days: days,
                                                                        enabled: enabled, strict: strict,
                                                                        list: list == limit.list ? nil : (list ?? 0)))
                if list == nil && picked != self.limitApps[limit.id] { self.setLimitApps(picked, for: limit.id) }
            } else {
                let made = try await self.api.createLimit(NewLimit(title: title, minutes: minutes, days: days,
                                                                   strict: strict, list: list))
                if list == nil { self.setLimitApps(picked, for: made.id) }
            }
        }
    }

    func setEnabled(_ limit: ScreenLimit, _ on: Bool) async {
        await change { _ = try await self.api.updateLimit(limit.id, LimitPatch(enabled: on)) }
    }

    /// Ends a limit reached today, until midnight.
    func unlock(_ limit: ScreenLimit, reason: String, pass: Bool = false) async -> Bool {
        let done = await change {
            _ = try await self.api.unlockLimit(limit.id, reason: reason, pass: pass)
            LockBook.limitOpened[limit.id] = LockBook.day()
        }
        if done { LockBook.openLimit(limit.id) }
        return done
    }

    func delete(_ limit: ScreenLimit) async -> Bool {
        let done = await change { try await self.api.deleteLimit(limit.id) }
        if done {
            limitApps[limit.id] = nil
            LockBook.limitApps = limitApps
        }
        return done
    }

    // MARK: Lists from the app

    /// This phone's pick of a list. Limits using it start counting afresh.
    private func setListApps(_ picked: FamilyActivitySelection, for id: Int) {
        listApps[id] = picked
        LockBook.listApps = listApps
        var scheduled = LockBook.scheduled
        for limit in limits where limit.list == id { scheduled[LockBook.limitActivity(limit.id).rawValue] = nil }
        LockBook.scheduled = scheduled
    }

    /// The name (and the Mac's apps, kept as they are) on the server, the phone's pick here.
    func saveList(_ list: ScreenList?, name: String, apps picked: FamilyActivitySelection) async -> Bool {
        await change {
            if let list {
                if name != list.name { _ = try await self.api.updateList(list.id, ScreenListBody(name: name)) }
                if picked != self.listApps[list.id] { self.setListApps(picked, for: list.id) }
            } else {
                let made = try await self.api.createList(ScreenListBody(name: name, mac: []))
                self.setListApps(picked, for: made.id)
            }
        }
    }

    func delete(_ list: ScreenList) async -> Bool {
        let done = await change { try await self.api.deleteList(list.id) }
        if done {
            listApps[list.id] = nil
            LockBook.listApps = listApps
        }
        return done
    }

    // MARK: Rations from the app

    func saveRation(_ ration: ScreenRation?, title: String, opens: Int, gap: Int, list: Int?,
                    apps picked: FamilyActivitySelection) async -> Bool {
        await change {
            let id: Int
            if let ration {
                _ = try await self.api.updateRation(ration.id, RationBody(title: title, opens: opens, gap: gap,
                                                                          list: list == ration.list ? nil : (list ?? 0)))
                id = ration.id
            } else {
                id = try await self.api.createRation(RationBody(title: title, opens: opens, gap: gap, list: list)).id
            }
            if list == nil {
                self.rationApps[id] = picked
                LockBook.rationApps = self.rationApps
            }
        }
    }

    func setEnabled(_ ration: ScreenRation, _ on: Bool) async {
        await change { _ = try await self.api.updateRation(ration.id, RationBody(enabled: on)) }
    }

    func delete(_ ration: ScreenRation) async -> Bool {
        await change { try await self.api.deleteRation(ration.id) }
    }

    /// One change on the server, then the list again. False (with `lastError`) if the server said no.
    @discardableResult
    private func change(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        await sync()
        return true
    }
}
