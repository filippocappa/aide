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
        } catch let error as APIError {
            if case .server(let status, _) = error, status == 400 { return .result() } // nothing to keep
            PaymentInbox.keep(payment)
        } catch {
            PaymentInbox.keep(payment)
        }
        return .result()
    }
}

/// Wallet taps the server didn't get yet, oldest first, in this app's defaults.
enum PaymentInbox {
    private static let key = "paymentInbox"
    private struct Waiting: Codable { let amount: String; let merchant: String; let card: String?; let at: String? }

    @MainActor static func keep(_ p: PaymentIn) {
        var list = waiting
        list.append(Waiting(amount: p.amount, merchant: p.merchant, card: p.card, at: p.at))
        save(Array(list.suffix(200)))
    }

    @MainActor static func flush(_ api: APIClient) async {
        var list = waiting
        while let first = list.first {
            do {
                _ = try await api.logPayment(PaymentIn(amount: first.amount, merchant: first.merchant, card: first.card,
                                                       at: first.at))
            } catch let error as APIError {
                if case .server(let status, _) = error, status == 400 {} else { break } // a bad one is dropped
            } catch { break }
            list.removeFirst()
            save(list)
        }
    }

    private static var waiting: [Waiting] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Waiting].self, from: data)) ?? []
    }

    private static func save(_ list: [Waiting]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
