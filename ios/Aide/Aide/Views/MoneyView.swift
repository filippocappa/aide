import SwiftUI
#if os(iOS)
import AppIntents
#endif

/// The Money tab, Finance's area (#31, docs/API.md "Finance"): Finance's line, the month as a ring (what's left of
/// the budget, or this month against last), the categories as bars, the latest payments by day, subscriptions by
/// date, and the accounts. Pull to refresh; the month arrows go back through earlier months.
struct MoneyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var settings: AppSettings

    @State private var month: FinanceMonth?
    @State private var shownMonth: Date = Self.firstMonth
    @State private var payments: [Payment] = []
    @State private var subscriptions: SubscriptionList?
    @State private var accounts: [FinanceAccount] = []
    @State private var error: String?
    @State private var open: Payment?
    @State private var editingBudget = false

    private var finance: Agent { chat.agent("finance") }
    private var tint: Color { finance.tint }
    private var isCurrent: Bool { Calendar.current.isDate(shownMonth, equalTo: .now, toGranularity: .month) }
    private var monthKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: shownMonth)
        return String(format: "%04d-%02d", c.year ?? 2026, c.month ?? 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TopBlock("Money", overline: shownMonth.formatted(.dateTime.month(.wide).year())) {
                        EmptyView()
                    } trailing: {
                        monthArrows
                    }
                    AgentLine(agent: finance, text: month?.line ?? Self.placeholder) {
                        push.route = .agent(finance.id)
                    }
                    .disabled(!settings.isConfigured)
                    if let error { ErrorCard(text: error) }
                    if let month, month.count > 0 || month.budget != nil {
                        MonthCard(month: month, tint: tint) { editingBudget = true }
                        if month.categories.contains(where: { $0.spent > 0 || $0.budget != nil }) {
                            header("Categories") {
                                Button("Budget") { editingBudget = true }
                            }
                            CategoryBars(month: month, tint: tint) { cat in
                                selectedCategory = cat
                            }
                        }
                    } else if month != nil && isCurrent {
                        setUp
                    }
                    if !shownPayments.isEmpty {
                        header("Payments") {
                            NavigationLink("All") { PaymentListView(tint: tint) }
                        }
                        PaymentDays(payments: shownPayments, tint: tint) { open = $0 }
                    }
                    if let subscriptions, !subscriptions.subscriptions.isEmpty, isCurrent {
                        header("Subscriptions", detail: "\(Euros.text(subscriptions.monthlyTotal)) a month")
                        SubscriptionsCard(list: subscriptions, tint: tint)
                    }
                    if !accounts.isEmpty, isCurrent {
                        header("Accounts")
                        AccountsCard(accounts: accounts, tint: tint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .pageColumn()
            }
            .pageGlow(tint)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task(id: monthKey + settings.serverURL + settings.token) { await load() }
            .navigationDestination(item: $selectedCategory) { cat in
                PaymentListView(category: cat, tint: tint)
            }
            .sheet(item: $open) { p in
                PaymentSheet(payment: p, tint: tint) { await load() }
            }
            .sheet(isPresented: $editingBudget) {
                BudgetSheet(tint: tint) { await load() }
                    #if os(macOS)
                    .toggleStyle(.phoneSwitch)
                    #endif
            }
        }
    }

    @State private var selectedCategory: FinanceCategory?

    /// The latest 12 payments; for an earlier month, that month's.
    private var shownPayments: [Payment] {
        let inMonth = payments.filter {
            guard let d = $0.date else { return false }
            return Calendar.current.isDate(d, equalTo: shownMonth, toGranularity: .month)
        }
        return Array(inMonth.prefix(12))
    }

    private var monthArrows: some View {
        HStack(spacing: 6) {
            arrow("chevron.left", by: -1)
            arrow("chevron.right", by: 1).disabled(isCurrent)
        }
    }

    private func arrow(_ icon: String, by months: Int) -> some View {
        Button {
            if let d = Calendar.current.date(byAdding: .month, value: months, to: shownMonth) {
                shownMonth = min(d, .now)
            }
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(months < 0 ? "Earlier month" : "Later month")
    }

    private func header<Trailing: View>(_ title: String, detail: String? = nil,
                                        @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            trailing().font(.subheadline.weight(.semibold)).foregroundStyle(tint).buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }

    /// Before the first tap: how payments come in.
    private var setUp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Every Apple Pay tap, sorted", systemImage: "wave.3.right")
                .font(.headline)
            Text("A Shortcuts automation sends each tap to Finance with Log payment: the amount, the shop and the card. Cash and transfers you can just tell \(finance.name).")
                .font(.subheadline).foregroundStyle(.secondary)
            NavigationLink { PaymentSetupView() } label: {
                Text("Set up Log payment").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Simulator screenshots: `-previewMonth 2026-10` opens on that month.
    private static var firstMonth: Date {
        #if DEBUG
        if let key = UserDefaults.standard.string(forKey: "previewMonth"), let d = Wire.day(key + "-15") { return d }
        #endif
        return .now
    }

    private static let placeholder = "Money in and out, sorted. Ask me anything about it."

    private func load() async {
        guard settings.isConfigured else { return }
        let key = isCurrent ? nil : monthKey
        async let m = env.api.financeMonth(key)
        async let p = env.api.payments(limit: 60, before: isCurrent ? nil : Self.monthEnd(shownMonth))
        async let s = env.api.subscriptions()
        async let a = env.api.financeAccounts()
        do {
            month = try await m
            payments = try await p.payments
            error = nil
        } catch {
            if (error as? CancellationError) == nil { self.error = error.localizedDescription }
        }
        subscriptions = try? await s
        accounts = (try? await a) ?? accounts
    }

    /// The first instant of the next month, as `before` for that month's payments.
    private static func monthEnd(_ d: Date) -> String? {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: d)?.end else { return nil }
        return Wire.utc(start)
    }
}

/// Settings → Payments: how to make the Wallet automation that runs Log payment.
struct PaymentSetupView: View {
    private static let steps: [(String, String)] = [
        ("1", "Open Shortcuts, then Automation, and tap +."),
        ("2", "Choose Transaction. Pick your cards (or all), leave every category on, and choose Run Immediately."),
        ("3", "New Blank Automation, then add Aide's Log payment."),
        ("4", "Tap Amount and pick Shortcut Input → Amount. Do the same for Merchant (Merchant) and Card (Card or Pass)."),
        ("5", "Done. The next tap shows up in Money within a few seconds, sorted."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.steps, id: \.0) { n, text in
                    HStack(alignment: .top, spacing: 12) {
                        Text(n).font(.subheadline.weight(.bold)).monospacedDigit()
                            .frame(width: 24, height: 24)
                            .background(Theme.chip, in: Circle())
                        Text(text).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("The Wallet automation")
            } footer: {
                Text("Wallet runs it on every Apple Pay tap, with the app closed. With no connection the tap waits on the phone and goes when Aide opens. A tap that comes twice is counted once.")
            }
            #if os(iOS)
            Section {
                ShortcutsLink()
            }
            #endif
            Section {
                Text("Cash, transfers and anything not paid with Apple Pay: tell Finance (\"8 euro for pizza\"). Bank accounts come later.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } header: {
                Text("Everything else")
            }
        }
        .navigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
    }
}
