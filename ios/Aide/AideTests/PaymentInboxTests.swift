import XCTest
@testable import Aide

/// Wallet taps waiting for the server (#36).
@MainActor
final class PaymentInboxTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "PaymentInboxTests-\(UUID().uuidString)")
    }

    private func tap(_ merchant: String) -> PaymentIn { PaymentIn(amount: "€4.50", merchant: merchant, card: nil, at: nil) }

    func testATapKeptDuringAFlushSurvives() async {
        PaymentInbox.keep(tap("Bar"), in: defaults)
        var sent: [String] = []
        await PaymentInbox.flush(defaults: defaults) { p in
            sent.append(p.merchant)
            if p.merchant == "Bar" { PaymentInbox.keep(self.tap("Tram"), in: self.defaults) } // a tap mid-send
            throw APIError.transport("offline") // ... and then the connection drops
        }
        XCTAssertEqual(sent, ["Bar"])
        XCTAssertEqual(PaymentInbox.waiting(defaults).map(\.merchant), ["Bar", "Tram"])

        await PaymentInbox.flush(defaults: defaults) { sent.append($0.merchant) }
        XCTAssertEqual(sent, ["Bar", "Bar", "Tram"])
        XCTAssertTrue(PaymentInbox.waiting(defaults).isEmpty)
    }

    func testARefusedTapDoesntBlockTheOnesAfterIt() async {
        for m in ["Bad", "Bar", "Tram"] { PaymentInbox.keep(tap(m), in: defaults) }
        var sent: [String] = []
        await PaymentInbox.flush(defaults: defaults) { p in
            if p.merchant == "Bad" { throw APIError.server(status: 422, message: "no") }
            sent.append(p.merchant)
        }
        XCTAssertEqual(sent, ["Bar", "Tram"])
        XCTAssertTrue(PaymentInbox.waiting(defaults).isEmpty)
    }

    func testTheTokenOrABusyServerKeepsTheTaps() async {
        PaymentInbox.keep(tap("Bar"), in: defaults)
        for error in [APIError.unauthorized, .server(status: 429, message: ""), .server(status: 503, message: "")] {
            await PaymentInbox.flush(defaults: defaults) { _ in throw error }
            XCTAssertEqual(PaymentInbox.waiting(defaults).count, 1, "\(error)")
        }
    }

    func testTwoIdenticalTapsAreTwo() async {
        PaymentInbox.keep(tap("Bar"), in: defaults)
        PaymentInbox.keep(tap("Bar"), in: defaults)
        var count = 0
        await PaymentInbox.flush(defaults: defaults) { _ in
            count += 1
            if count == 1 { throw APIError.transport("offline") }
        }
        XCTAssertEqual(PaymentInbox.waiting(defaults).count, 2)
        await PaymentInbox.flush(defaults: defaults) { _ in count += 1 }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(PaymentInbox.waiting(defaults).isEmpty)
    }
}
