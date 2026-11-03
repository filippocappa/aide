import XCTest
@testable import Aide

/// Which reminders missing from a fetch go up as deleted (#35).
final class DeletePlanTests: XCTestCase {
    private func entries(_ n: Int, list: String = "Inbox", from start: Int = 0) -> [String: SnapshotEntry] {
        Dictionary(uniqueKeysWithValues: (start..<start + n).map {
            ("r\($0)", SnapshotEntry(serverID: "s\($0)", modifiedAt: .distantPast, needsReport: false, list: list))
        })
    }

    func testOneDeleteGoesUpAtOnce() {
        let all = entries(10)
        let plan = DeletePlan.make(entries: all, seen: Set(all.keys).subtracting(["r3"]), lists: ["Inbox"],
                                   held: nil, now: Date())
        XCTAssertEqual(plan.send, ["r3"])
        XCTAssertNil(plan.held)
    }

    func testAListThePhoneCantSeeDeletesNothing() {
        let all = entries(4, list: "Inbox").merging(entries(8, list: "Shopping", from: 4)) { a, _ in a }
        let seen = Set(all.filter { $0.value.list == "Inbox" }.keys)
        let plan = DeletePlan.make(entries: all, seen: seen, lists: ["Inbox"], held: nil, now: Date())
        XCTAssertTrue(plan.send.isEmpty)
        XCTAssertEqual(plan.kept.count, 8)
        XCTAssertNil(plan.held)
    }

    func testAMassDeleteIsHeldThenSentOnALaterPass() {
        let all = entries(12)
        let seen: Set<String> = ["r0", "r1", "r2"]
        let t0 = Date()
        let first = DeletePlan.make(entries: all, seen: seen, lists: ["Inbox"], held: nil, now: t0)
        XCTAssertTrue(first.send.isEmpty)
        XCTAssertEqual(first.held?.ids.count, 9)
        XCTAssertEqual(first.kept.count, 9)

        // The same sync's quick extra pass doesn't count as a second look.
        let quick = DeletePlan.make(entries: all, seen: seen, lists: ["Inbox"], held: first.held, now: t0 + 5)
        XCTAssertTrue(quick.send.isEmpty)
        XCTAssertEqual(quick.held?.since, t0)

        let later = DeletePlan.make(entries: all, seen: seen, lists: ["Inbox"], held: first.held, now: t0 + 120)
        XCTAssertEqual(later.send.count, 9)
        XCTAssertTrue(later.kept.isEmpty)
        XCTAssertNil(later.held)
    }

    func testAHeldDeleteThatCameBackIsDropped() {
        let all = entries(12)
        let t0 = Date()
        let first = DeletePlan.make(entries: all, seen: ["r0"], lists: ["Inbox"], held: nil, now: t0)
        XCTAssertNotNil(first.held)
        let back = DeletePlan.make(entries: all, seen: Set(all.keys), lists: ["Inbox"], held: first.held, now: t0 + 120)
        XCTAssertTrue(back.send.isEmpty)
        XCTAssertNil(back.held)
    }

    func testOldStateWithoutHeldStillDecodes() throws {
        let json = #"{"cursor":"7","entries":{}}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        XCTAssertNil(state.held)
        XCTAssertEqual(state.cursor, "7")
    }
}
