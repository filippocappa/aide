import AuthenticationServices
import SwiftUI

/// Money → Banks (docs/API.md, "Banks"): the linked banks with their accounts and how long the link lasts, linking
/// one (the bank's own login page in a browser sheet), renewing (linking it again) and unlinking. Read-only:
/// Enable Banking, a licensed PSD2 provider, can't move money.
struct BanksView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    let tint: Color
    var changed: () async -> Void = {}

    @State private var list: BankList?
    @State private var accounts: [FinanceAccount] = []
    @State private var picking = false
    @State private var linking: String?
    @State private var reading = false
    @State private var unlinking: BankLink?
    @State private var error: String?
    @State private var note: String?
    @State private var webLogin = WebLogin()

    var body: some View {
        List {
            if let list, !list.enabled {
                Section {
                    Text("Bank sync is off on the server: it needs an Enable Banking application (ENABLE_BANKING_APP_ID and ENABLE_BANKING_KEY in its .env).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let note {
                Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(list?.banks ?? []) { bank in
                Section {
                    statusRow(bank)
                    ForEach(accounts.filter { $0.bankId == bank.id }) { a in
                        accountRow(a)
                    }
                    if bank.status != "linked" {
                        Button(linking == bank.bank ? "Opening the bank…" : "Renew the link") {
                            Task { await link(bank.bank) }
                        }
                        .disabled(linking != nil)
                    }
                    Button("Unlink", role: .destructive) { unlinking = bank }
                } header: {
                    Text(bank.bank)
                }
            }
            if list?.enabled ?? false {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label(linking.map { "Opening \($0)…" } ?? "Link a bank", systemImage: "building.columns")
                    }
                    .disabled(linking != nil)
                    if !(list?.banks.isEmpty ?? true) {
                        Button(reading ? "Reading…" : "Read now") { Task { await readNow() } }
                            .disabled(reading)
                    }
                } footer: {
                    Text("An account left out of Money (a credit line that's always below zero) isn't in the accounts or the total; its payments still count. You log in on your bank's own page. Aide only reads balances and transactions, through Enable Banking (a licensed PSD2 provider); nothing can move money. It reads four times a day and whenever Money opens. A link lasts up to 180 days; a week before it ends you're asked to renew. The data stays on your server.")
                }
            }
        }
        .navigationTitle("Banks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $picking) {
            BankPicker(tint: tint) { bank in
                picking = false
                Task { await link(bank.name) }
            }
        }
        .confirmationDialog(unlinking.map { "Unlink \($0.bank)?" } ?? "", isPresented: Binding(
            get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }
        ), titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                if let bank = unlinking { Task { await unlink(bank) } }
            }
        } message: {
            Text("Aide stops reading it. Its accounts and payments stay; link it again any time.")
        }
    }

    @ViewBuilder
    private func accountRow(_ a: FinanceAccount) -> some View {
        let kind = a.hidden ? "Hidden from Money" : a.kind == "card" ? "Card" : "Account"
        LabeledContent {
            if let balance = a.balance {
                Text(Euros.text(balance)).monospacedDigit().foregroundStyle(a.hidden ? Color.secondary : Color.primary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("Show in Money", isOn: Binding(get: { !a.hidden }, set: { show in Task { await setShown(a, show) } }))
            #if os(macOS)
            .toggleStyle(.phoneSwitch)
            #endif
    }

    private func statusRow(_ bank: BankLink) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(bank)).frame(width: 8, height: 8)
                Text(statusText(bank)).font(.subheadline.weight(.semibold))
            }
            if let line = syncLine(bank) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if let err = bank.error {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ bank: BankLink) -> Color {
        switch bank.status {
        case "linked": .green
        case "renew": .orange
        default: .red
        }
    }

    private func statusText(_ bank: BankLink) -> String {
        switch bank.status {
        case "expired": return "The link ended"
        case "renew": return "Ends in \(max(bank.daysLeft ?? 0, 0)) days"
        default:
            guard let until = bank.validUntil.flatMap(Wire.parse) else { return "Linked" }
            return "Linked until \(until.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    private func syncLine(_ bank: BankLink) -> String? {
        guard let at = bank.lastSyncAt.flatMap(Wire.parse) else { return nil }
        let ago = AccountsCard.ago(at)
        return ago.prefix(1).uppercased() + ago.dropFirst()
    }

    private func load() async {
        do {
            async let b = env.api.banks()
            async let a = env.api.financeAccounts()
            list = try await b
            accounts = (try? await a)?.accounts ?? accounts
            error = nil
        } catch {
            if (error as? CancellationError) == nil { self.error = error.localizedDescription }
        }
    }

    /// The bank's login page in a browser sheet; it ends on `aide://money/banks?linked=<id>` or `?error=`.
    private func link(_ name: String) async {
        linking = name
        note = nil
        defer { linking = nil }
        do {
            let server = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try await env.api.linkBank(BankLinkIn(bank: name, server: server.isEmpty ? nil : server))
            let callback = try await webLogin.start(url, scheme: "aide")
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let problem = items.first(where: { $0.name == "error" })?.value {
                error = Self.explain(problem)
            } else {
                error = nil
                note = "\(name) is linked. The last 90 days are in Money."
            }
            await load()
            await changed()
        } catch let cancelled as ASWebAuthenticationSessionError where cancelled.code == .canceledLogin {
            // Closed the sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setShown(_ account: FinanceAccount, _ show: Bool) async {
        do {
            let updated = try await env.api.setAccountHidden(account.id, !show)
            if let i = accounts.firstIndex(where: { $0.id == updated.id }) { accounts[i] = updated }
            error = nil
            await changed()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func readNow() async {
        reading = true
        defer { reading = false }
        do {
            let r = try await env.api.syncBanks(force: true)
            list?.banks = r.banks
            note = r.new == 0 ? "Nothing new." : r.new == 1 ? "1 new payment." : "\(r.new) new payments."
            error = nil
            accounts = (try? await env.api.financeAccounts())?.accounts ?? accounts
            await changed()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unlink(_ bank: BankLink) async {
        unlinking = nil
        do {
            try await env.api.unlinkBank(bank.id)
            note = nil
            await load()
            await changed()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The bank's or the server's words, a little kinder.
    static func explain(_ problem: String) -> String {
        switch problem {
        case "access_denied", "cancelled": "The bank wasn't linked: the login was cancelled."
        default: "The bank wasn't linked: \(problem)"
        }
    }
}

/// Picking the bank to link, from Enable Banking's list for Italy, with a search.
struct BankPicker: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let tint: Color
    let pick: (AvailableBank) -> Void

    @State private var banks: [AvailableBank] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true

    private var shown: [AvailableBank] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? banks : banks.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if shown.isEmpty {
                    Text("No bank called \"\(query)\".").foregroundStyle(.secondary)
                }
                ForEach(shown) { bank in
                    Button { pick(bank) } label: {
                        HStack(spacing: 12) {
                            logo(bank)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bank.name).foregroundStyle(.primary)
                                Text(caption(bank)).font(.caption).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search banks")
            #else
            .searchable(text: $query, prompt: "Search banks")
            #endif
            .navigationTitle("Link a bank")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle("Link a bank")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #endif
            }
            .task { await load() }
        }
    }

    private func logo(_ bank: AvailableBank) -> some View {
        AsyncImage(url: bank.logo.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFit().padding(4)
        } placeholder: {
            Image(systemName: "building.columns").foregroundStyle(tint)
        }
        .frame(width: 36, height: 36)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func caption(_ bank: AvailableBank) -> String {
        var parts: [String] = []
        if let days = bank.days { parts.append("A link lasts \(days) days") }
        if bank.beta { parts.append("beta") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            banks = try await env.api.availableBanks()
            error = nil
        } catch {
            if (error as? CancellationError) == nil { self.error = error.localizedDescription }
        }
    }
}
