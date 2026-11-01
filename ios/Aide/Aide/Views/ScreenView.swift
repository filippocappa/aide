import DeviceActivity
import FamilyControls
import SwiftUI

/// The Screen tab: where the phone's time went, for a day, a week or a month. The total is every app's time added
/// up, so it's the same as the list under it (Apple's own total isn't). The page under the date is drawn by the
/// UsageReport extension (`UsageReportView`), the only place iOS shows which apps were used; the app keeps the title,
/// the switch, the date and the locks (Lock now in the corner, Locks and limits under the date). iPhone only.
struct ScreenView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var screenTime: ScreenTimeService
    @AppStorage("screenKind") private var kind = UsageKind.day
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var showLocks = false

    private var period: DateInterval { UsageMath.period(kind, containing: date) }
    private var isCurrent: Bool { period.contains(Date()) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(alignment: .top) { glow }
            .background(Theme.grouped)
            .toolbar(.hidden, for: .navigationBar) // Lock now sits on the title's line
            .navigationDestination(isPresented: $showLocks) { ScreenTimeView() }
            .task { await screenTime.sync() }
        }
    }

    /// The page's cyan, faded out by the end of the header (the report under it draws its own page).
    private var glow: some View {
        LinearGradient(colors: [UsageColors.cyan[0].opacity(0.32), UsageColors.cyan[0].opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 420)
            .ignoresSafeArea()
    }

    private var header: some View {
        TopBlock("Screen") {
            Picker("Show", selection: Binding(get: { kind }, set: { k in withAnimation(.snappy) { kind = k } })) {
                Text("Day").tag(UsageKind.day)
                Text("Week").tag(UsageKind.week)
                Text("Month").tag(UsageKind.month)
            }
            .pickerStyle(.segmented)
            dateRow
            locksRow
        } trailing: {
            lockMenu
        }
    }

    private var dateRow: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Earlier")
            Spacer()
            Text(periodTitle).font(.headline).contentTransition(.numericText())
            Spacer()
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
        withAnimation(.snappy) { date = min(next, Calendar.current.startOfDay(for: Date())) }
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

    /// Lock now from the corner: a length, or a strict one; while a lock holds, when it ends.
    private var lockMenu: some View {
        Menu {
            if let (lock, until) = screenTime.current {
                Section("\(lock.title): locked until \(ScreenTimeView.time(until))") {
                    Button("Locks and limits") { showLocks = true }
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
            DeviceActivityReport(.usage(kind), filter: .usage(kind, containing: date))
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
