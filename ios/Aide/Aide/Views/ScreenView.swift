import DeviceActivity
import FamilyControls
import SwiftUI

/// Health's Screen half: where the phone's time went, for a day, a week or a month. The total is every app's time
/// added up, so it's the same as the list under it (Apple's own total isn't). The page under the date is drawn by the
/// UsageReport extension (`UsageReportView`), the only place iOS shows which apps were used; this keeps the switch,
/// the date and Locks and limits. Health's title bar holds it, with Lock now (`ScreenLockMenu`) in its corner.
/// iPhone only.
struct ScreenView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var screenTime: ScreenTimeService
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @AppStorage("screenKind") private var kind = UsageKind.day
    @State private var date = Calendar.current.startOfDay(for: Date())
    /// The way the last arrow went, which the title slides.
    @State private var forward = false
    /// Locks and limits; shared with the corner's menu.
    @Binding var showLocks: Bool

    private var period: DateInterval { UsageMath.period(kind, containing: date) }
    private var isCurrent: Bool { period.contains(Date()) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .background { glow }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.grouped)
        .navigationDestination(isPresented: $showLocks) { ScreenTimeView().macPageBack() }
        .task { await screenTime.sync() }
    }

    /// The page's cyan, gone by the end of the header: the report under it draws its own opaque page.
    private var glow: some View {
        LinearGradient(colors: [UsageColors.cyan[0].opacity(0.32), UsageColors.cyan[0].opacity(0.04),
                                UsageColors.cyan[0].opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Show", selection: $kind) {
                Text("Day").tag(UsageKind.day)
                Text("Week").tag(UsageKind.week)
                Text("Month").tag(UsageKind.month)
            }
            .pickerStyle(.segmented)
            dateRow
            locksRow
            // Coach's line, as on Body and Food: what holds now or comes next, so only on the period with today in it.
            if isCurrent, let line = screenTime.line {
                let coach = chat.agent("coach")
                AgentLine(agent: coach, text: line) { push.route = .agent(coach.id) }
            }
        }
        .padding(.horizontal, 4)
    }

    private var dateRow: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Earlier")
            // The title slides the way you went; the page under it changes at once (it's drawn by another process, and
            // moving it with the title made both stutter), and its bars grow in.
            ZStack {
                Text(periodTitle).font(.headline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .id(periodTitle)
                    .transition(.push(from: forward ? .trailing : .leading))
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .animation(.snappy(duration: 0.3), value: periodTitle)
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .disabled(isCurrent)
            .accessibilityLabel("Later")
        }
        .font(.body.weight(.semibold))
        .tint(.primary)
    }

    private var periodTitle: String {
        let calendar = Calendar.current
        switch kind {
        case .day:
            let day = "\(date.formatted(.dateTime.weekday(.abbreviated))) \(date.formatted(.dateTime.day().month(.abbreviated)))"
            if calendar.isDateInToday(date) { return "Today, \(day)" }
            if calendar.isDateInYesterday(date) { return "Yesterday, \(day)" }
            return day
        case .week:
            let last = period.end.addingTimeInterval(-1)
            let range = "\(period.start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
            return isCurrent ? "This week, \(range)" : range
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }

    private func step(_ by: Int) {
        let unit: Calendar.Component = kind == .day ? .day : kind == .week ? .weekOfYear : .month
        guard let next = Calendar.current.date(byAdding: unit, value: by, to: date) else { return }
        forward = by > 0
        date = min(next, Calendar.current.startOfDay(for: Date()))
    }

    /// Locks and limits (the locks page, which was in Settings), with what holds now or comes next.
    private var locksRow: some View {
        Button { showLocks = true } label: {
            HStack(spacing: 10) {
                Image(systemName: screenTime.current == nil ? "lock" : "lock.fill")
                    .foregroundStyle(UsageColors.cyan[1])
                Text("Locks and limits")
                Spacer()
                Text(locksValue).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var locksValue: String {
        if let (_, until) = screenTime.current { return "Locked until \(ScreenTimeView.time(until))" }
        let next = screenTime.locks.compactMap { lock in LockClock.date(lock.next).map { (lock, $0) } }
            .filter { $0.1 > Date() }.min { $0.1 < $1.1 }
        if let (lock, at) = next { return "\(lock.title) at \(ScreenTimeView.time(at))" }
        let count = screenTime.locks.filter { !$0.once }.count
        return count == 0 ? "None yet" : "\(count) lock\(count == 1 ? "" : "s")"
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if settings.isPreview {
            // A fixed evening, so screenshots look like a used day whatever the time.
            let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(21 * 3600 + 40 * 60)
            UsageReportView(data: UsageSample.data(kind, containing: date, now: now), now: now).id("\(kind)\(date)")
        } else {
            report
        }
        #else
        report
        #endif
    }

    @ViewBuilder private var report: some View {
        if screenTime.isAuthorized {
            UsageReportHost(kind: kind, date: date)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "hourglass").font(.system(size: 40)).foregroundStyle(UsageColors.cyan[1])
                    Text("See where your time goes").font(.title3.weight(.semibold))
                    Text(screenTime.authorization == .denied
                         ? "Screen Time is off for Aide. Turn it on in iOS Settings → Screen Time → Apps with Screen Time Access."
                         : "Every app's time, added up, by hour and by day, and how it compares with your usual. It stays on this phone: iOS shows it to you, not to Aide's server.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { Task { await screenTime.authorize() } } label: {
                        Text("Allow Screen Time").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }
}

/// A report's page: the day, week or month with `date` in it.
private struct UsagePage: Hashable {
    let kind: UsageKind
    let date: Date

    /// The day, week or month before.
    var earlier: UsagePage {
        let unit: Calendar.Component = kind == .day ? .day : kind == .week ? .weekOfYear : .month
        return UsagePage(kind: kind, date: Calendar.current.date(byAdding: unit, value: -1, to: date) ?? date)
    }
}

/// The reports alone, with nothing from the page's environment, so a chat reply or a Screen Time sync redrawing the
/// page doesn't make them ask iOS again. iOS is slow to read the usage, so reports are read ahead and kept: the one
/// shown, the one before it (asked a moment after, so it doesn't slow the shown one down) and the last one shown,
/// each drawn hidden until it's the page. Going back a day or returning to one is then instant. A page not read yet
/// shows the placeholder behind until its report fades in (`UsageReportView`).
private struct UsageReportHost: View {
    let kind: UsageKind
    let date: Date
    @State private var kept: [UsagePage] = []
    @State private var filling = false
    /// `usageFill` runs once a launch.
    @MainActor private static var filled = false

    private var shown: UsagePage { UsagePage(kind: kind, date: date) }
    private var today: UsagePage { UsagePage(kind: kind, date: Calendar.current.startOfDay(for: Date())) }
    private static let keep = 4

    var body: some View {
        ZStack(alignment: .top) {
            UsageSkeleton(page: shown)
            ForEach(kept.contains(shown) ? kept : [shown] + kept, id: \.self) { page in
                let on = page == shown
                DeviceActivityReport(.usage(page.kind), filter: .usage(page.kind, containing: page.date))
                    .padding(.trailing, on ? 0 : 1) // hidden a point narrower: the report grows its bars when shown
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(on)
                    .accessibilityHidden(!on)
                    .zIndex(on ? 1 : 0)
            }
            if filling {
                DeviceActivityReport(.usageFill, filter: .usageFill)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task {
            guard !Self.filled else { return }
            Self.filled = true
            filling = true
            try? await Task.sleep(for: .seconds(30))
            filling = false
        }
        .task(id: shown) {
            add(shown)
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            add(shown.earlier)
        }
    }

    /// Keeps `page`, the shown one first and today's (the one most come back to), dropping the oldest past `keep`.
    private func add(_ page: UsagePage) {
        var pages = [shown]
        for p in [page, today] + kept where !pages.contains(p) { pages.append(p) }
        kept = Array(pages.prefix(Self.keep))
    }
}

/// The report's shape while iOS reads the usage: the summary card (the number, the stats, the bars) and the first
/// apps, in grey, breathing.
private struct UsageSkeleton: View {
    /// The page being read: the pulse starts again when it changes.
    let page: UsagePage
    @State private var dim = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        bar(width: 150, height: 11)
                        bar(width: 170, height: 44)
                        bar(width: 190, height: 14)
                    }
                    Spacer()
                    Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 10).frame(width: 110, height: 110)
                }
                Divider().opacity(0.4)
                HStack {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) { bar(width: 44, height: 16); bar(width: 64, height: 11) }
                        Spacer()
                    }
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach([18, 30, 8, 4, 12, 40, 70, 24, 10, 6, 14, 20], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18))
                            .frame(height: CGFloat(h) * 1.4)
                    }
                }
                .frame(height: 100, alignment: .bottom)
            }
            .padding(16)
            .background(UsageColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                bar(width: 100, height: 16)
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.18))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 8) {
                            bar(width: CGFloat(120 - i * 15), height: 13)
                            bar(width: nil, height: 6)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UsageColors.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        // Only the space under the header: taller, the page (which doesn't scroll) grew past the screen and pushed
        // Health's title up under the status bar.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .opacity(dim ? 0.5 : 1)
        // A few breaths each time the page changes, then still: it sits under the report once that's drawn (and
        // under Body and Food, where Screen stays loaded), and a pulse that never ends redraws every frame there.
        .task(id: page) {
            for _ in 0..<4 {
                withAnimation(.easeInOut(duration: 0.9)) { dim = true }
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeInOut(duration: 0.9)) { dim = false }
                try? await Task.sleep(for: .seconds(0.9))
                if Task.isCancelled { break }
            }
            dim = false
        }
        .accessibilityLabel("Loading screen time")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2.5, style: .continuous).fill(Color.secondary.opacity(0.18))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(width: width, height: height)
    }
}

/// Lock now, in Health's corner while the Screen half is shown: a length, or a strict one; while a lock holds, when
/// it ends.
struct ScreenLockMenu: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    let openLocks: () -> Void

    var body: some View {
        Menu {
            if let (lock, until) = screenTime.current {
                Section("\(lock.title): locked until \(ScreenTimeView.time(until))") {
                    Button("Locks and limits", action: openLocks)
                }
            } else {
                Section("Lock now") {
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Button(ScreenTimeView.length(minutes)) { Task { await screenTime.lockNow(minutes: minutes) } }
                    }
                    Menu {
                        ForEach([30, 60, 120, 240], id: \.self) { minutes in
                            Button(ScreenTimeView.length(minutes)) {
                                Task { await screenTime.lockNow(minutes: minutes, strict: true) }
                            }
                        }
                    } label: {
                        Label("Strict", systemImage: "lock.shield")
                    }
                }
            }
        } label: {
            CornerIcon(systemImage: screenTime.current == nil ? "lock" : "lock.fill")
        }
        .buttonStyle(.plain)
        .disabled(!screenTime.isAuthorized)
        .accessibilityLabel("Lock now")
    }

}
