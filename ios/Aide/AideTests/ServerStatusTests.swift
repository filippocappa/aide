import XCTest
@testable import Aide

final class ServerStatusTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T17:10:00Z")!

    private func host(_ state: String = "active", since: String = "2026-11-18T16:57:10Z", at: String = "2026-11-18T17:09:55Z",
                      claude: [HostStatus.Session] = [], dev: [String] = []) -> HostStatus {
        HostStatus(at: at, aide: .init(state: state, since: since), claude: claude, dev: dev)
    }

    func testAllWellShowsNothing() {
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: host(), now: now))
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: nil, now: now))
        let idle = host(claude: [.init(project: "aide", busy: false)])
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: idle, now: now))
    }

    func testNothingAnswers() {
        XCTAssertEqual(ServerCondition.from(answering: false, reached: false, host: nil, now: now)?.title, "Can't reach cappa")
    }

    func testStoppedSaysWhy() {
        let h = host("inactive", claude: [.init(project: "roenlabs", busy: true)], dev: ["Android emulator", "Metro"])
        let c = ServerCondition.from(answering: false, reached: true, host: h, now: now)
        XCTAssertEqual(c?.title, "Aide is stopped")
        XCTAssertEqual(c?.detail, "Claude is working in roenlabs. Android emulator and Metro are running.")
    }

    func testStartingAndCrashed() {
        XCTAssertEqual(ServerCondition.from(answering: false, reached: true, host: host("activating"), now: now)?.title,
                       "Aide is starting")
        XCTAssertEqual(ServerCondition.from(answering: false, reached: true, host: host("failed"), now: now)?.title,
                       "Aide crashed")
    }

    func testStaleStatusIsIgnored() {
        let old = host("inactive", at: "2026-11-18T16:00:00Z")
        XCTAssertEqual(ServerCondition.from(answering: false, reached: true, host: old, now: now)?.title,
                       "Aide isn't answering")
        let busy = host(at: "2026-11-18T16:00:00Z", claude: [.init(project: "aide", busy: true)])
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: busy, now: now))
    }

    func testClaudeOnAideBeforeOtherWork() {
        let h = host(claude: [.init(project: "aide", busy: true)], dev: ["Expo"])
        XCTAssertEqual(ServerCondition.from(answering: true, reached: true, host: h, now: now)?.title,
                       "Claude is working on Aide")
        let elsewhere = host(claude: [.init(project: "roenlabs", busy: true)])
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: elsewhere, now: now)) // not a risk alone
    }

    func testBusyWhileDevRunsOrMemoryIsLow() {
        let dev = host(dev: ["Android emulator", "Expo"])
        let c = ServerCondition.from(answering: true, reached: true, host: dev, now: now)
        XCTAssertEqual(c?.short, "Busy")
        XCTAssertEqual(c?.detail, "Android emulator and Expo are running. Aide may be slow, or stopped to make room.")
        var low = host()
        low.memory = .init(totalMb: 15391, availableMb: 1800, aideMaxMb: 8192)
        XCTAssertEqual(ServerCondition.from(answering: true, reached: true, host: low, now: now)?.short, "Busy")
        var fine = host()
        fine.memory = .init(totalMb: 15391, availableMb: 7000, aideMaxMb: 8192)
        XCTAssertNil(ServerCondition.from(answering: true, reached: true, host: fine, now: now))
    }

    func testJustRestarted() {
        let h = host(since: "2026-11-18T17:09:30Z")
        XCTAssertEqual(ServerCondition.from(answering: true, reached: true, host: h, now: now)?.title, "Aide just restarted")
    }

    func testDecodesTheServersJSON() throws {
        let json = """
        {"at":"2026-11-18T17:04:17Z","aide":{"state":"active","since":"2026-11-18T16:57:10Z"},
         "voice":{"state":"active"},"claude":[{"project":"roenlabs","busy":false}],"dev":[],
         "memory":{"total_mb":15391,"available_mb":7829,"aide_max_mb":8192}}
        """
        let h = try JSONDecoder.api.decode(HostStatus.self, from: Data(json.utf8))
        XCTAssertEqual(h.claude.first?.project, "roenlabs")
        XCTAssertEqual(h.memory?.aideMaxMb, 8192)
    }
}
