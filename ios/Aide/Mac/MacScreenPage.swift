import SwiftUI

/// The Screen section: where this Mac's time went, for a day, a week or a month, as the phone's Screen tab shows the
/// phone's. The phone reads Apple's Screen Time; the Mac counts its own (`MacUsage`), so the page under the date is the
/// phone's `UsageReportView` drawn from this Mac's days. In the corner Lock now and the gear (Locks and limits, the
/// page's settings); under the date a line only while a lock or a limit holds.
struct MacScreenPage: View {
    @EnvironmentObject private var screenTime: ScreenTimeService
    @ObservedObject private var usage = MacUsage.shared
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
                    .pageColumn(760)
                UsageReportView(data: usage.data(kind, containing: date), now: Date())
                    .id("\(kind)\(date)\(usage.revision)")
                    .pageColumn(760)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(alignment: .top) { glow }
            .background(Theme.grouped)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLocks) { MacScreenTimeView() }
            .task { await screenTime.sync() }
        }
    }

    private var glow: some View {
        LinearGradient(colors: [UsageColors.cyan[0].opacity(0.28), UsageColors.cyan[0].opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 420)
            .ignoresSafeArea()
    }

    private var header: some View {
        TopBlock("Screen", overline: "This Mac") {
            Picker("Show", selection: Binding(get: { kind }, set: { k in withAnimation(.snappy) { kind = k } })) {
                Text("Day").tag(UsageKind.day)
                Text("Week").tag(UsageKind.week)
                Text("Month").tag(UsageKind.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            dateRow
            if let holding { holdingRow(holding) }
        } trailing: {
            HStack(spacing: 10) {
                lockMenu
                Button { showLocks = true } label: { CornerIcon(systemImage: "gearshape") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                    .help("Locks and limits (⇧⌘,)")
            }
        }
    }

    private var dateRow: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Earlier (←)")
            Spacer()
            Text(periodTitle).font(.headline).contentTransition(.numericText())
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(isCurrent)
            .help("Later (→)")
        }
        .font(.body.weight(.semibold))
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

    /// What holds now: a lock until a time, or the limits used up today. Nothing when nothing does.
    private var holding: String? {
        if let (lock, until) = screenTime.current { return "\(lock.title): locked until \(MacScreenTimeView.time(until))" }
        let used = screenTime.limits.filter { screenTime.holds($0) }
        guard let first = used.first else { return nil }
        return used.count == 1 ? "\(first.title) used up for today" : "\(used.count) limits used up for today"
    }

    private func holdingRow(_ text: String) -> some View {
        Button { showLocks = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(UsageColors.cyan[1])
                Text(text).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var lockMenu: some View {
        Menu {
            if let (lock, until) = screenTime.current {
                Section("\(lock.title): locked until \(MacScreenTimeView.time(until))") {
                    Button("Locks and limits…") { showLocks = true }
                }
            } else {
                Section("Lock now: \(usualNames)") {
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Button(MacScreenTimeView.length(minutes)) { Task { await screenTime.lockNow(minutes: minutes) } }
                    }
                    Menu("Strict") {
                        ForEach([30, 60, 120, 240], id: \.self) { minutes in
                            Button(MacScreenTimeView.length(minutes)) {
                                Task { await screenTime.lockNow(minutes: minutes, strict: true) }
                            }
                        }
                    }
                }
            }
        } label: {
            CornerIcon(systemImage: screenTime.current == nil ? "lock" : "lock.fill")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(screenTime.current == nil && screenTime.usualApps.isEmpty)
        .help("Lock now")
    }

    private var usualNames: String {
        let names = screenTime.usualApps.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }.sorted()
        if names.count <= 2 { return names.joined(separator: " and ") }
        return "\(names[0]) and \(names.count - 1) more"
    }
}
