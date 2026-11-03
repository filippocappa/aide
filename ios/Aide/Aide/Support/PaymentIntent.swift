import AppIntents
import Foundation

// A Wallet tap to Finance (#31, docs/API.md "Finance"). A Shortcuts personal automation (Transaction: when I tap any
// card) runs Log payment with the shortcut input's Amount, Merchant and Card or Pass; it goes straight to the server
// without opening the app. When the server can't be reached (Tailscale off, no signal) the tap waits in
// `PaymentInbox` with its own time and goes when the app next comes forward; a tap sent twice is one on the server.

struct LogPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log payment"
    static var description = IntentDescription(
        "Sends a card payment to Aide's Finance. Use it in a Wallet automation (Transaction): Amount, Merchant and Card or Pass from the Shortcut Input.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", description: "As Wallet gives it, e.g. €4.50") var amount: String
    @Parameter(title: "Merchant") var merchant: String
    @Parameter(title: "Card", description: "The card or pass Wallet names") var card: String?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") { \.$card }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let payment = PaymentIn(amount: amount, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
                                card: card?.isEmpty == false ? card : nil, at: Wire.local(.now))
        guard !payment.amount.isEmpty, !payment.merchant.isEmpty else { return .result() }
        do {
            _ = try await AppEnvironment.shared.api.logPayment(payment)
            await PaymentInbox.flush(AppEnvironment.shared.api)
        } catch {
            if !PaymentInbox.isRefused(error) { PaymentInbox.keep(payment) } // a refused one would never go
        }
        return .result()
    }
}

/// Wallet taps the server didn't get yet, oldest first, in this app's defaults (#36: none lost, none stuck).
enum PaymentInbox {
    private static let key = "paymentInbox"
    /// A runaway guard only: months of taps with no connection.
    static let limit = 1000

    struct Waiting: Codable, Equatable {
        /// Tells two identical taps apart, so a flush removes the one it sent. Nil in taps kept before it.
        var id: String? = UUID().uuidString
        let amount: String
        let merchant: String
        let card: String?
        let at: String?

        var payment: PaymentIn { PaymentIn(amount: amount, merchant: merchant, card: card, at: at) }
    }

    /// One flush at a time: the app coming forward and a tap's intent can both start one.
    @MainActor private static var flushing = false

    @MainActor static func keep(_ p: PaymentIn, in defaults: UserDefaults = .standard) {
        var list = waiting(defaults)
        list.append(Waiting(amount: p.amount, merchant: p.merchant, card: p.card, at: p.at))
        save(Array(list.suffix(limit)), defaults)
    }

    @MainActor static func flush(_ api: APIClient) async {
        await flush(defaults: .standard) { _ = try await api.logPayment($0) }
    }

    /// Sends the waiting taps oldest first. Each sent (or refused) tap is taken off a fresh read of the list, so
    /// a tap kept meanwhile stays. Stops at the first that can't go now (offline, the token, the server down).
    @MainActor static func flush(defaults: UserDefaults, send: (PaymentIn) async throws -> Void) async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let first = waiting(defaults).first {
            do {
                try await send(first.payment)
            } catch {
                if !isRefused(error) { break }
            }
            var list = waiting(defaults)
            if let i = list.firstIndex(of: first) { list.remove(at: i) }
            save(list, defaults)
        }
    }

    /// The server read the tap and won't take it, ever: a 4xx other than a timeout or too many requests
    /// (a 401 is the token, `.unauthorized`, and waits for it to be fixed).
    static func isRefused(_ error: Error) -> Bool {
        guard case .server(let status, _) = error as? APIError else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }

    static func waiting(_ defaults: UserDefaults = .standard) -> [Waiting] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Waiting].self, from: data)) ?? []
    }

    private static func save(_ list: [Waiting], _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
