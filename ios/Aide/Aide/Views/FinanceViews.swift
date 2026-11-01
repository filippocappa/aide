import SwiftUI

// Finance's pieces (#31, docs/API.md "Finance"), chosen in the design pass: the month as a ring of what's left, the
// categories as bars against a budget with a tick for today, payments by day with their category's icon, a payment's
// page with the amount on top and the category as a row, subscriptions as a list by date, a row per account with
// its status. A budget is optional and never nags: being over it is said once, in orange words.

enum Euros {
    private static let locale = Locale(identifier: "en_IE")

    /// €4.50, €1,234.56; `whole`: €1,235.
    static func text(_ value: Double, whole: Bool = false) -> String {
        value.formatted(.currency(code: "EUR").locale(locale).precision(.fractionLength(whole ? 0 : 2)))
    }

    /// A payment's amount: −€4.50 out, +€300.00 in.
    static func signed(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + text(abs(value))
    }
}

/// A category's icon in a soft square of Finance's colour.
struct CategoryIcon: View {
    let category: FinanceCategory
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: category.icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

// MARK: The month

/// What's left of the budget as a ring that drains through the month, Spent, Budget and a day beside it. Without a budget the ring is this month
/// against the whole of last month, with last month by the same day beside it.
struct MonthCard: View {
    let month: FinanceMonth
    let tint: Color
    var setBudget: () -> Void = {}

    private var fill: Double {
        if let budget = month.budget, budget > 0 { return max(0, min(1, (month.left ?? 0) / budget)) } // drains
        if let total = month.lastMonth.total, total > 0 { return min(1, month.spent / total) }
        return month.spent > 0 ? 1 : 0
    }

    private var over: Bool { (month.left ?? 0) < 0 }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(centre).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(over ? Color.orange : .primary)
                    Text(centreCaption).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 116, height: 116)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fill)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.0) { label, value in
                    HStack {
                        Text(label).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                if month.budget == nil && month.current {
                    Button("Set a budget", action: setBudget)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                        .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    private var centre: String {
        if let left = month.left { return Euros.text(abs(left), whole: true) }
        return Euros.text(month.spent, whole: true)
    }

    private var centreCaption: String {
        if month.left != nil { return over ? "over" : "left" }
        return "spent"
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if let budget = month.budget {
            rows.append(("Spent", Euros.text(month.spent)))
            rows.append(("Budget", Euros.text(budget, whole: true)))
            if month.current, let perDay = month.perDay {
                rows.append(("A day", "\(Euros.text(perDay, whole: perDay >= 100)) · \(month.daysLeft) d"))
            }
        } else {
            if let byNow = month.lastMonth.byNow, month.current {
                rows.append(("Last month by now", Euros.text(byNow, whole: true)))
            }
            if let total = month.lastMonth.total { rows.append(("Last month", Euros.text(total, whole: true))) }
            if rows.isEmpty { rows.append(("Payments", "\(month.count)")) }
        }
        if month.income > 0 { rows.append(("In", Euros.text(month.income, whole: true))) }
        return rows
    }
}

// MARK: Categories

/// A row per category: what's spent, a bar to its budget with a tick where it should be by today (or, with no budget,
/// a bar against the biggest with the tick at last month by the same day). Orange words only when it's ahead.
struct CategoryBars: View {
    let month: FinanceMonth
    let tint: Color
    let open: (FinanceCategory) -> Void

    private var shown: [FinanceMonth.Category] { month.categories.filter { $0.spent > 0 || $0.budget != nil } }

    private var scale: Double {
        max(1, shown.map { max($0.spent, month.current ? $0.lastByNow : $0.lastTotal) }.max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(shown) { c in
                Button { open(c.cat) } label: { row(c) }
                    .buttonStyle(.plain)
                if c.id != shown.last?.id { Divider().padding(.leading, 62) }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func row(_ c: FinanceMonth.Category) -> some View {
        let warn = month.current && c.ahead && !c.cat.isFixed
        return HStack(spacing: 12) {
            CategoryIcon(category: c.cat, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.name).font(.subheadline)
                    Spacer(minLength: 8)
                    trailing(c, warn: warn)
                }
                bar(c, warn: warn)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func trailing(_ c: FinanceMonth.Category, warn: Bool) -> some View {
        if let budget = c.budget {
            if c.over {
                Text("\(Euros.text(c.spent - budget, whole: true)) over").font(.subheadline).foregroundStyle(.orange)
            } else if warn {
                Text("\(Euros.text(budget - c.spent, whole: true)) left").font(.subheadline).foregroundStyle(.orange)
            } else {
                Text("\(Euros.text(c.spent, whole: true)) of \(Euros.text(budget, whole: true))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Text(Euros.text(c.spent, whole: c.spent >= 100)).font(.subheadline.weight(.medium))
        }
    }

    private func bar(_ c: FinanceMonth.Category, warn: Bool) -> some View {
        let full = c.budget ?? scale
        let mark: Double? = c.budget != nil ? (c.cat.isFixed || !month.current ? nil : c.pace)
                                            : (month.current ? c.lastByNow : c.lastTotal)
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.13))
                if c.spent > 0 {
                    Capsule().fill(warn || c.over ? Color.orange : tint)
                        .frame(width: max(6, w * min(1, c.spent / max(full, 0.01))))
                }
                if let mark, mark > 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 12)
                        .offset(x: min(w - 2, w * min(1, mark / max(full, 0.01))))
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel(c.budget.map { "\(Euros.text(c.spent)) of \(Euros.text($0))" } ?? Euros.text(c.spent))
    }
}

// MARK: Payments

struct PaymentRow: View {
    let payment: Payment
    let tint: Color
    var showsTime = false

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: payment.cat, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.merchant).font(.body).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Euros.signed(payment.amount))
                .font(.body.weight(payment.amount > 0 ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(payment.amount > 0 ? Color.green : .primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var caption: String {
        var parts = [payment.sortedBy == "none" ? "Sorting…" : payment.cat.name]
        if let account = payment.account { parts.append(account) }
        if showsTime, let d = payment.date { parts.append(d.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

/// Payments grouped by day, newest first: a header with the day's spending, then a card of rows.
struct PaymentDays: View {
    let payments: [Payment]
    let tint: Color
    let open: (Payment) -> Void

    private var days: [(day: Date, rows: [Payment])] {
        let cal = Calendar.current
        var out: [(Date, [Payment])] = []
        for p in payments {
            let d = cal.startOfDay(for: p.date ?? .now)
            if let i = out.indices.last, out[i].0 == d { out[i].1.append(p) } else { out.append((d, [p])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Self.dayTitle(day.day))
                        Spacer()
                        let spent = -day.rows.filter { $0.isSpending }.map(\.amount).reduce(0, +)
                        if spent > 0 { Text(Euros.text(spent)).monospacedDigit() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    VStack(spacing: 0) {
                        ForEach(day.rows) { p in
                            Button { open(p) } label: { PaymentRow(payment: p, tint: tint, showsTime: true) }
                                .buttonStyle(.plain)
                            if p.id != day.rows.last?.id { Divider().padding(.leading, 64) }
                        }
                    }
                    .padding(.vertical, 2)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: .now)).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Every payment, paged 50 at a time, optionally one category's.
struct PaymentListView: View {
    @EnvironmentObject private var env: AppEnvironment
    var category: FinanceCategory?
    let tint: Color

    @State private var payments: [Payment] = []
    @State private var more = false
    @State private var loaded = false
    @State private var error: String?
    @State private var open: Payment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBlock(category?.name ?? "Payments", overline: category == nil ? nil : "Payments")
                if let error { ErrorCard(text: error) }
                if loaded && payments.isEmpty && error == nil {
                    Text("No payments yet.").font(.subheadline).foregroundStyle(.secondary).card()
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                PaymentDays(payments: payments, tint: tint) { open = $0 }
                if more {
                    ProgressView().frame(maxWidth: .infinity).padding()
                        .task { await load(more: true) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .pageColumn()
        }
        .background(Theme.grouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .sheet(item: $open) { p in
            PaymentSheet(payment: p, tint: tint) { await load() }
        }
    }

    private func load(more next: Bool = false) async {
        do {
            let list = try await env.api.payments(limit: 50, before: next ? payments.last?.at : nil,
                                                  category: category?.id)
            payments = next ? payments + list.payments : list.payments
            more = list.more
            error = nil
        } catch {
            self.error = error.localizedDescription
            more = false
        }
        loaded = true
    }
}

// MARK: A payment's page

/// The merchant and amount large, the category as a row (Change opens the list; kept for the merchant unless the
/// switch is off), what's spent there, Ask Finance. Edits go to the server at once.
struct PaymentSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @Environment(\.dismiss) private var dismiss

    @State var payment: Payment
    let tint: Color
    var changed: () async -> Void = {}

    @State private var detail: PaymentDetail?
    @State private var remember = true
    @State private var error: String?
    @State private var confirmDelete = false

    private var finance: Agent { chat.agent("finance") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    VStack(spacing: 0) {
                        NavigationLink {
                            CategoryPicker(selected: payment.category, tint: tint) { pick($0) }
                        } label: {
                            HStack(spacing: 12) {
                                CategoryIcon(category: payment.cat, tint: tint, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(payment.sortedBy == "none" ? "Not sorted yet" : payment.cat.name)
                                    Text(sortedLine).font(.caption).foregroundStyle(.secondary)
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text("Change").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                        Toggle(isOn: $remember) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Keep it for \(payment.merchant)")
                                Text("Its other payments and the next ones follow").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        #if os(macOS)
                        .toggleStyle(.phoneSwitch)
                        #endif
                        .tint(Theme.toggle)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    if let error { ErrorCard(text: error) }
                    if let m = detail?.merchant, m.count > 1 { atMerchant(m) }
                    askFinance
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .pageColumn()
            }
            .background(Theme.grouped)
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle(payment.merchant)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                #endif
                ToolbarItem(placement: .sheetDone) {
                    Menu {
                        Button("Delete payment", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("More")
                }
            }
            .confirmationDialog("Delete this payment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("For one logged by mistake or twice. It won't come back from Wallet.")
            }
            .task { await loadDetail() }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(spacing: 4) {
            CategoryIcon(category: payment.cat, tint: tint, size: 64)
            Text(payment.merchant).font(.headline).multilineTextAlignment(.center).padding(.top, 6)
            Text(Euros.signed(payment.amount))
                .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(payment.amount > 0 ? Color.green : .primary)
            Text(whenLine).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let note = payment.note, !note.isEmpty {
                Text(note).font(.callout).padding(.top, 4).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var whenLine: String {
        var parts: [String] = []
        if let d = payment.date {
            let day = Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday"
                : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            parts.append("\(day), \(d.formatted(date: .omitted, time: .shortened))")
        }
        switch payment.source {
        case "wallet": parts.append(payment.account.map { "Apple Pay on \($0)" } ?? "Apple Pay")
        case "manual": parts.append(payment.account.map { "Told to Finance · \($0)" } ?? "Told to Finance")
        default: if let a = payment.account { parts.append(a) }
        }
        return parts.joined(separator: " · ")
    }

    private var sortedLine: String {
        switch payment.sortedBy {
        case "user": "Category · yours"
        case "rule": "Category · as before for \(payment.merchant)"
        case "model": "Category · Finance's guess"
        default: "Finance is sorting it"
        }
    }

    private func atMerchant(_ m: PaymentDetail.Merchant) -> some View {
        DetailCard("At \(payment.merchant)", padding: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.count) payments").font(.subheadline.weight(.semibold))
                    Text("All time").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Euros.text(m.monthTotal)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            ForEach(m.recent.filter { $0.id != payment.id }.prefix(4)) { p in
                Divider().padding(.leading, 16)
                HStack {
                    Text(p.date.map { PaymentDays.dayTitle($0) } ?? "").font(.subheadline)
                    Spacer()
                    Text(Euros.signed(p.amount)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var askFinance: some View {
        Button {
            dismiss()
            push.route = .agent(finance.id)
        } label: {
            HStack(spacing: 12) {
                AgentMark(agent: finance, size: 28)
                Text("Ask \(finance.name) about it").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
    }

    private func pick(_ category: FinanceCategory) {
        guard category.id != payment.category || payment.sortedBy != "user" else { return }
        let before = payment
        payment.category = category.id
        payment.sortedBy = "user"
        Task {
            do {
                payment = try await env.api.updatePayment(payment.id, PaymentPatch(category: category.id, remember: remember))
                error = nil
                await changed()
            } catch {
                payment = before
                self.error = error.localizedDescription
            }
        }
    }

    private func loadDetail() async {
        do {
            let d = try await env.api.payment(payment.id)
            detail = d
            payment = d.payment
        } catch {}
    }

    private func delete() async {
        do {
            try await env.api.deletePayment(payment.id)
            await changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Every category, the current one ticked; picking one goes back.
struct CategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let tint: Color
    let pick: (FinanceCategory) -> Void

    var body: some View {
        List {
            Section("Spending") { ForEach(FinanceCategory.spending) { row($0) } }
            Section {
                ForEach(FinanceCategory.all.filter { FinanceCategory.notSpending.contains($0.id) }) { row($0) }
            } header: {
                Text("Not spending")
            } footer: {
                Text("Transfer is money moving between your own accounts.")
            }
        }
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ c: FinanceCategory) -> some View {
        Button {
            pick(c)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CategoryIcon(category: c, tint: tint, size: 30)
                Text(c.name).foregroundStyle(.primary)
                Spacer()
                if c.id == selected { Image(systemName: "checkmark").foregroundStyle(tint).fontWeight(.semibold) }
            }
        }
    }
}

// MARK: Subscriptions and accounts

/// The next charge first with "in 6 days"; a price that went up says so in orange.
struct SubscriptionsCard: View {
    let list: SubscriptionList
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(list.subscriptions) { s in
                HStack(spacing: 12) {
                    Text(String(s.merchant.prefix(1)).uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.merchant).lineLimit(1)
                        Text(Self.when(s)).font(.caption).foregroundStyle(.secondary)
                        if let was = s.priceWas, was < s.amount {
                            Text("Was \(Euros.text(was))").font(.caption.weight(.medium)).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Euros.text(s.amount)).monospacedDigit()
                        Text("a \(s.period)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if s.id != list.subscriptions.last?.id { Divider().padding(.leading, 64) }
            }
        }
        .padding(.vertical, 2)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    static func when(_ s: Subscription) -> String {
        guard let next = Wire.day(s.next) else { return "Next \(s.next)" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: next).day ?? 0
        let date = next.formatted(.dateTime.day().month(.abbreviated))
        switch days {
        case ..<0: return "Was due \(date)"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "In \(days) days · \(date)"
        }
    }
}

/// A row per account with how its payments get here.
struct AccountsCard: View {
    let accounts: [FinanceAccount]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(accounts) { a in
                HStack(spacing: 12) {
                    Text(String(a.name.prefix(1)).uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).lineLimit(1)
                        Text(Self.status(a)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        if let balance = a.balance {
                            Text(Euros.text(balance)).fontWeight(.semibold).monospacedDigit()
                        } else {
                            Text(Euros.text(a.spentMonth, whole: a.spentMonth >= 100)).monospacedDigit()
                            Text("this month").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if a.id != accounts.last?.id { Divider().padding(.leading, 64) }
            }
        }
        .padding(.vertical, 2)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    static func status(_ a: FinanceAccount) -> String {
        let source = switch a.status {
        case "wallet": "Apple Pay taps"
        case "bank": "Linked to the bank"
        case "statement": "From statements"
        default: "Told to Finance"
        }
        guard let last = a.lastAt.flatMap(Wire.parse) else { return source }
        return "\(source) · last \(PaymentDays.dayTitle(Calendar.current.startOfDay(for: last)).lowercased())"
    }
}

// MARK: The budget

/// The monthly budget and, if wanted, some categories'. Empty fields are no budget.
struct BudgetSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let tint: Color
    var saved: () async -> Void = {}

    @State private var monthly = ""
    @State private var categories: [String: String] = [:]
    @State private var loaded = FinanceBudget()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("A month") {
                        TextField("None", text: $monthly)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                } footer: {
                    Text("Optional. With one, the Money page shows what's left and how much a day; without, this month against last month.")
                }
                Section {
                    ForEach(FinanceCategory.spending) { c in
                        LabeledContent {
                            TextField("None", text: Binding(get: { categories[c.id] ?? "" },
                                                            set: { categories[c.id] = $0 }))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                        } label: {
                            Label { Text(c.name) } icon: { Image(systemName: c.icon).foregroundStyle(tint) }
                        }
                    }
                } header: {
                    Text("By category")
                } footer: {
                    Text("Each gets a tick for where it should be by today.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle("Budget")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #endif
                ToolbarItem(placement: .sheetDone) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .task { await load() }
        }
    }

    private static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v > 0 else { return nil }
        return v
    }

    private static func field(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    private func load() async {
        do {
            loaded = try await env.api.budget()
            monthly = Self.field(loaded.monthly)
            categories = loaded.categories.mapValues { Self.field($0) }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var cats: [String: Double?] = [:]
        for c in FinanceCategory.spending {
            let v = Self.number(categories[c.id] ?? "")
            if v != loaded.categories[c.id] { cats[c.id] = v }
        }
        do {
            _ = try await env.api.setBudget(BudgetIn(monthly: Self.number(monthly), categories: cats))
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: In chat

/// The `payments` attachment: rows that open the payment's page.
struct PaymentsCard: View {
    @EnvironmentObject private var chat: ChatViewModel
    let payments: [Payment]
    @State private var open: Payment?

    private var tint: Color { chat.agent("finance").tint }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(payments) { p in
                Button { open = p } label: { PaymentRow(payment: p, tint: tint, showsTime: false) }
                    .buttonStyle(.plain)
                if p.id != payments.last?.id { Divider().padding(.leading, 64) }
            }
        }
        .padding(.vertical, 2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(item: $open) { PaymentSheet(payment: $0, tint: tint) }
    }
}
