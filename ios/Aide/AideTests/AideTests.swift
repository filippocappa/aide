import XCTest
@testable import Aide

final class ModelTests: XCTestCase {
    func testReminderDecodesNullsAndMissingFields() throws {
        let json = #"{"id":"a","title":"Call","due_at":null,"completed":false,"apple_id":null,"modified_at":"2026-10-18T11:20:00Z"}"#
        let r = try JSONDecoder.api.decode(Reminder.self, from: Data(json.utf8))
        XCTAssertNil(r.dueAt)
        XCTAssertNil(r.appleId)
        XCTAssertEqual(r.notes, "")
        XCTAssertFalse(r.deleted)
    }

    func testTodayDecodesAllDayEvent() throws {
        let json = #"""
        {"date":"2026-10-18","reminders":[],"events":[
          {"id":"x@aide","title":"Trip","calendar":"Travel","start":"2026-10-18","end":"2026-10-19","all_day":true,"location":null,"recurring":false}]}
        """#
        let t = try JSONDecoder.api.decode(TodayResponse.self, from: Data(json.utf8))
        XCTAssertTrue(t.events[0].allDay)
        XCTAssertEqual(t.events[0].timeText, "All day")
        XCTAssertNotNil(t.events[0].startDate)
    }

    func testChatReplyDecodesPending() throws {
        let json = #"{"reply":"ok","pending":[{"id":42,"summary":"Move it"}]}"#
        let r = try JSONDecoder.api.decode(ChatReply.self, from: Data(json.utf8))
        XCTAssertEqual(r.pending, [PendingAction(id: 42, summary: "Move it")])
    }

    func testSyncRequestSendsExplicitNulls() throws {
        let change = ReminderChange(id: nil, appleId: "x-apple", title: "Buy milk", notes: "", dueAt: nil,
                                    completed: false, modifiedAt: "2026-10-18T11:26:10Z", deleted: false)
        let data = try JSONEncoder.api.encode(SyncRequest(cursor: nil, changes: [change]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(obj["cursor"] is NSNull)
        let c = try XCTUnwrap((obj["changes"] as? [[String: Any]])?.first)
        XCTAssertTrue(c["id"] is NSNull)
        XCTAssertTrue(c["due_at"] is NSNull)
        XCTAssertEqual(c["apple_id"] as? String, "x-apple")
        XCTAssertEqual(c["modified_at"] as? String, "2026-10-18T11:26:10Z")
    }

    func testSyncSendsListsAndEachReminderItsList() throws {
        let change = ReminderChange(id: nil, appleId: "x-apple", title: "Milk", notes: "", dueAt: nil, completed: false,
                                    modifiedAt: "2026-10-18T11:26:10Z", deleted: false, list: "Groceries")
        let data = try JSONEncoder.api.encode(SyncRequest(cursor: "3", changes: [change], lists: ["Reminders", "Groceries"],
                                                          defaultList: "Reminders"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["lists"] as? [String], ["Reminders", "Groceries"])
        XCTAssertEqual(obj["default_list"] as? String, "Reminders")
        XCTAssertEqual((obj["changes"] as? [[String: Any]])?.first?["list"] as? String, "Groceries")
        let r = try JSONDecoder.api.decode(Reminder.self, from: Data(
            #"{"id":"a","title":"Milk","list":"Groceries","modified_at":"2026-10-18T11:26:10Z"}"#.utf8))
        XCTAssertEqual(r.list, "Groceries")
        XCTAssertNil(try JSONDecoder.api.decode(Reminder.self, from: Data(#"{"id":"b","title":"x"}"#.utf8)).list)
    }

    private static let buffer = 1024.0 / 48_000 // one microphone buffer

    /// Feeds `db` for `seconds`; true if any buffer counted as talking.
    private func feed(_ d: inout SpeechDetector, _ db: (Int) -> Double, for seconds: Double, strict: Bool = false) -> Bool {
        var talking = false
        for i in 0..<Int(seconds / Self.buffer) where d.feed(db(i), duration: Self.buffer, strict: strict) { talking = true }
        return talking
    }

    func testSpeechDetectorHearsYouAfterASilence() {
        var d = SpeechDetector()
        XCTAssertFalse(feed(&d, { _ in -70 }, for: 5), "a quiet room isn't talking")
        XCTAssertTrue(feed(&d, { _ in -42 }, for: 0.3), "a normal voice after it is")
        XCTAssertFalse(feed(&d, { _ in -70 }, for: 1), "and quiet again isn't")
    }

    func testSpeechDetectorIgnoresTheStartFansAndClicks() {
        var d = SpeechDetector()
        XCTAssertFalse(feed(&d, { _ in -20 }, for: 0.25), "the moment the microphone starts doesn't count")
        d.reset()
        XCTAssertFalse(feed(&d, { -45 + Double($0 % 5) - 2 }, for: 6), "a steady fan isn't talking")
        XCTAssertFalse(feed(&d, { _ in -10 }, for: 0.05), "a click isn't")
        XCTAssertTrue(feed(&d, { _ in -25 }, for: 0.3), "a voice over the fan is")
    }

    func testTheRoomBetweenSentencesDoesntKeepTheTurnOpen() {
        var d = SpeechDetector()
        XCTAssertFalse(feed(&d, { _ in -75 }, for: 3))
        XCTAssertTrue(feed(&d, { _ in -20 }, for: 1), "you, close to the phone")
        XCTAssertFalse(feed(&d, { $0 % 3 == 0 ? -52 : -60 }, for: 2), "a TV or people between your sentences")
        XCTAssertTrue(feed(&d, { _ in -35 }, for: 0.3), "your next sentence, a bit quieter")
        d.newTurn()
        XCTAssertFalse(feed(&d, { _ in -60 }, for: 0.2), "a new turn starts from the room's noise again, not your voice")
    }

    func testTalkingOverAideTakesMore() {
        var d = SpeechDetector()
        XCTAssertFalse(feed(&d, { _ in -70 }, for: 2))
        XCTAssertFalse(feed(&d, { _ in -56 }, for: 0.5, strict: true), "Aide's echo isn't you")
        XCTAssertTrue(feed(&d, { _ in -35 }, for: 0.5, strict: true), "a clear voice over it is")
    }

    func testSyncResponseAcceptsNumericCursor() throws {
        let r = try JSONDecoder.api.decode(SyncResponse.self, from: Data(#"{"cursor":1720,"reminders":[]}"#.utf8))
        XCTAssertEqual(r.cursor, "1720")
    }

    func testWireDatesRoundTrip() throws {
        let d = try XCTUnwrap(Wire.parse("2026-10-20T17:00:00+02:00"))
        XCTAssertEqual(d, Wire.parse(Wire.local(d)))
        XCTAssertEqual(d, Wire.parse(Wire.utc(d)))
        XCTAssertEqual(Wire.utc(d), "2026-10-20T15:00:00Z")
        XCTAssertNotNil(Wire.parse("2026-10-20T17:00:00.250000+02:00"))
        XCTAssertEqual(Wire.dayString(try XCTUnwrap(Wire.day("2026-10-18"))), "2026-10-18")
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, body: String))?
    static var headers: [String: String]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class APIClientTests: XCTestCase {
    private func makeClient(config: APIConfig? = APIConfig(baseURL: URL(string: "https://aide.test/")!, token: "secret")) -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return APIClient(session: URLSession(configuration: cfg), config: { config })
    }

    func testSendsBearerTokenAndQuery() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { seen = $0; return (200, #"{"messages":[]}"#) }
        _ = try await makeClient().history(limit: 20)
        XCTAssertEqual(seen?.url?.absoluteString, "https://aide.test/v1/history?limit=20")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testHealthSendsNoToken() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { seen = $0; return (200, #"{"ok":true,"version":"0.2.0"}"#) }
        let h = try await makeClient().health()
        XCTAssertEqual(h.version, "0.2.0")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedMapsToError() async {
        StubURLProtocol.handler = { _ in (401, #"{"error":"nope"}"#) }
        do { _ = try await makeClient().today(); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? APIError, .unauthorized) }
    }

    func testServerErrorMessageSurfaces() async {
        StubURLProtocol.handler = { _ in (502, #"{"error":"Claude is down"}"#) }
        do { _ = try await makeClient().chat("hi"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? APIError, .server(status: 502, message: "Claude is down")) }
    }

    func testChatLiveReadsTheStream() async throws {
        StubURLProtocol.headers = ["Content-Type": "text/event-stream"]
        defer { StubURLProtocol.headers = nil }
        var body: [String: Any]?
        StubURLProtocol.handler = { req in
            body = req.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(buffer, count: n) }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (200, """
            : keep-alive

            event: team
            data: {"from": "aide", "to": "coach", "text": "Gym tonight?"}

            event: team
            data: {"from": "coach", "to": "aide", "text": "Easy session."}

            event: text
            data: {"delta": "Coach says", "restart": true}

            event: text
            data: {"delta": " easy."}

            event: reply
            data: {"reply": "Coach says easy.", "team": [{"from": "aide", "to": "coach", "text": "Gym tonight?"}, {"from": "coach", "to": "aide", "text": "Easy session."}]}

            """)
        }
        var live: [TeamMessage] = []
        var draft: [(String, Bool)] = []
        let reply = try await makeClient().chatLive("gym?", conversationID: "c_1", onText: { draft.append(($0, $1)) }) {
            live.append($0)
        }
        XCTAssertEqual(live.map(\.from), ["aide", "coach"])
        XCTAssertEqual(draft.map(\.0), ["Coach says", " easy."])
        XCTAssertEqual(draft.map(\.1), [true, false])
        XCTAssertEqual(reply.reply, "Coach says easy.")
        XCTAssertEqual(reply.team, live)
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["conversation_id"] as? String, "c_1")
    }

    func testChatLiveFallsBackToPlainJSON() async throws {
        StubURLProtocol.handler = { _ in (200, #"{"reply":"hi","pending":[]}"#) }
        let reply = try await makeClient().chatLive("hi") { _ in XCTFail("nothing live from an old server") }
        XCTAssertEqual(reply.reply, "hi")
        XCTAssertEqual(reply.team, [])
    }

    func testTeamPostStreamsWorkingAndMessages() async throws {
        StubURLProtocol.headers = ["Content-Type": "text/event-stream"]
        defer { StubURLProtocol.headers = nil }
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/v1/team")
            return (200, """
            event: team
            data: {"from": "user", "to": "team", "text": "@coach recovery?", "conversation_id": null}

            event: working
            data: {"agent": "coach"}

            event: team
            data: {"from": "coach", "to": "team", "text": "Good, HRV is back to usual."}

            event: done
            data: {"messages": [{"from": "user", "to": "team", "text": "@coach recovery?"}, {"from": "coach", "to": "team", "text": "Good, HRV is back to usual."}], "pending": []}

            """)
        }
        var seen: [String] = []
        let reply = try await makeClient().postTeam("@coach recovery?") { event in
            switch event {
            case .working(let agent): seen.append("working:" + agent)
            case .team(let m): seen.append("team:" + m.from)
            default: seen.append("other")
            }
        }
        XCTAssertEqual(seen, ["team:user", "working:coach", "team:coach"])
        XCTAssertEqual(reply.messages.count, 2)
        XCTAssertEqual(reply.pending, [])
    }

    func testStreamErrorSurfaces() {
        var stream = EventStream()
        XCTAssertNil(try stream.feed("event: error"))
        XCTAssertThrowsError(try stream.feed(#"data: {"error": "Claude is down"}"#)) {
            XCTAssertEqual($0 as? APIError, .server(status: 500, message: "Claude is down"))
        }
        // Unknown events are skipped, and the name resets after each data line.
        XCTAssertNil(try stream.feed("event: progress"))
        XCTAssertNil(try stream.feed(#"data: {"x": 1}"#))
        XCTAssertNil(try stream.feed(#"data: {"reply": "plain message event"}"#))
    }

    func testMissingConfigFailsBeforeNetwork() async {
        StubURLProtocol.handler = { _ in XCTFail("no request expected"); return (200, "{}") }
        do { _ = try await makeClient(config: nil).today(); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? APIError, .notConfigured) }
    }
}

final class RichTextTests: XCTestCase {
    func testCalendarReplyBecomesOneAgendaBlock() {
        let blocks = RichText.parse("**Tomorrow**\n- 09:00–10:00 Dentist\n- All day: Trip\nNothing else.")
        guard blocks.count == 2, case .agenda(let title, let events) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(title, "Tomorrow")
        XCTAssertEqual(events, [.init(start: "09:00", end: "10:00", title: "Dentist"),
                                .init(start: "All day", end: nil, title: "Trip")])
    }
}

final class DigestTests: XCTestCase {
    func testDigestDecodesKnownAndUnknownSections() throws {
        let json = #"""
        {"kind":"daily","generated_at":"2026-10-19T08:00:03+02:00","greeting":"Good morning.","sections":[
          {"type":"calendar","title":"Today","events":[{"id":"e1","title":"Dentist","calendar":"Home","start":"2026-10-19T15:00:00+02:00","end":"2026-10-19T16:00:00+02:00","all_day":false,"location":null,"recurring":false}]},
          {"type":"mail","title":"Mail","items":[{"id":"m1","from":"Dr. Rossi","subject":"Appointment","preview":"See you","received_at":"2026-10-19T07:00:00Z","unread":true}]},
          {"type":"habits","title":"Habits","habits":[{"id":3,"name":"Gym","cadence":{"type":"weekly","per_week":3},"streak":4,"done_today":false,"last_done":null}]},
          {"type":"hologram","title":"Future"}]}
        """#
        let d = try JSONDecoder.api.decode(Digest.self, from: Data(json.utf8))
        XCTAssertEqual(d.sections.count, 4)
        guard case .calendar(let events) = d.sections[0].content, case .habits(let habits) = d.sections[2].content,
              case .unknown = d.sections[3].content else { return XCTFail("wrong section kinds") }
        XCTAssertEqual(events[0].calendar, "Home")
        XCTAssertEqual(habits[0].cadenceText, "3× a week")
    }
}

final class PushTests: XCTestCase {
    func testRoutesFromPayloads() {
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "digest", "digest": "evening"]]), .digest("evening"))
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "reminder", "reminder_id": "6f1c"]]), .today)
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "message", "conversation_id": "c_91f"]]), .conversation("c_91f"))
    }

    func testSilentTestAndUnknownPushesDontRoute() {
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "moodle"]]), .moodle(login: false))
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "moodle", "login": true]]), .moodle(login: true))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "sync"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "test"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "something-new"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "message"]]))
        XCTAssertNil(PushRoute(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertTrue(PushRoute.isSync(["aps": ["content-available": 1], "aide": ["kind": "sync"]]))
        XCTAssertFalse(PushRoute.isSync(["aide": ["kind": "digest"]]))
    }

    @MainActor
    func testTokenIsLowercaseHex() {
        XCTAssertEqual(PushService.hex(Data([0x0a, 0xff, 0x00, 0x7b])), "0aff007b")
    }

    func testDeviceRegistrationIsSnakeCase() throws {
        let data = try JSONEncoder.api.encode(DeviceRegistration(token: "ab", environment: "sandbox", name: "iPhone"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(obj, ["token": "ab", "environment": "sandbox", "name": "iPhone"])
    }
}

final class HealthTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    /// 2026-10-19 at h:m in Rome; negative hours or hours past 23 roll over to the days around it.
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        return midnight.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
    }

    private func seg(_ stage: SleepSegment.Stage, _ from: (Int, Int), _ to: (Int, Int)) -> SleepSegment {
        SleepSegment(stage: stage, start: at(from.0, from.1), end: at(to.0, to.1))
    }

    func testWatchNightUsesStagesAndIgnoresPhoneDuplicates() throws {
        let segments = [
            seg(.inBed, (-1, 30), (8, 0)),
            seg(.asleep, (0, 0), (7, 30)), // iPhone, same night
            seg(.core, (0, 10), (2, 0)),
            seg(.deep, (2, 0), (3, 0)),
            seg(.awake, (3, 0), (3, 20)),
            seg(.rem, (3, 20), (4, 20)),
            seg(.core, (4, 20), (7, 40)),
        ]
        let night = try XCTUnwrap(SleepSummary.night(endingOn: at(12), from: segments, calendar: calendar))
        XCTAssertEqual(Wire.parse(night.bedtime), at(0, 10))
        XCTAssertEqual(Wire.parse(night.wake), at(7, 40))
        XCTAssertEqual(night.inBedMin, 450)
        XCTAssertEqual(night.asleepMin, 430)
        XCTAssertEqual(night.awakeMin, 20)
        XCTAssertEqual(night.deepMin, 60)
        XCTAssertEqual(night.remMin, 60)
        XCTAssertEqual(night.coreMin, 310)
    }

    func testNapIsNotTheNightAndShortGapsJoin() throws {
        let segments = [
            seg(.asleep, (-1, 0), (3, 0)),
            seg(.asleep, (3, 40), (7, 0)), // 40 min gap: same night
            seg(.asleep, (14, 0), (14, 40)), // nap
        ]
        let night = try XCTUnwrap(SleepSummary.night(endingOn: at(12), from: segments, calendar: calendar))
        XCTAssertEqual(Wire.parse(night.bedtime), at(-1))
        XCTAssertEqual(Wire.parse(night.wake), at(7))
        XCTAssertEqual(night.asleepMin, 440)
        XCTAssertNil(night.deepMin)
    }

    func testNightEndingTheDayBeforeIsNotThisDays() {
        let segments = [seg(.core, (-24, 0), (-17, 0))] // ended 07:00 on the 18th
        XCTAssertNil(SleepSummary.night(endingOn: at(12), from: segments, calendar: calendar))
    }

    func testHealthDayEncodesSnakeCaseAndLeavesOutMissing() throws {
        let day = HealthDay(date: "2026-10-19", restingHr: 52, hrvMs: 61.5, wristTempC: 35.91, steps: 8432)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(day)) as? [String: Any])
        XCTAssertEqual(obj["resting_hr"] as? Int, 52)
        XCTAssertEqual(obj["hrv_ms"] as? Double, 61.5)
        XCTAssertEqual(obj["wrist_temp_c"] as? Double, 35.91)
        XCTAssertNil(obj["sleep"])
        XCTAssertEqual((obj["workouts"] as? [Any])?.count, 0)
    }

    func testDigestDecodesSleepAndRecovery() throws {
        let json = #"""
        {"kind":"wake","greeting":"Morning.","sections":[
          {"type":"sleep","title":"Last night","usual_asleep_min":438,"sleep":{"bedtime":"2026-10-19T00:12:00+02:00",
           "wake":"2026-10-19T07:41:00+02:00","asleep_min":412,"in_bed_min":449,"awake_min":37,"deep_min":58,"core_min":251,"rem_min":103}},
          {"type":"recovery","title":"Recovery","level":"good","summary":"HRV above your usual.","hrv_ms":61.5,"hrv_usual_ms":55.0,
           "resting_hr":52,"resting_hr_usual":54}]}
        """#
        let digest = try JSONDecoder.api.decode(Digest.self, from: Data(json.utf8))
        guard case .sleep(let night, let usual) = digest.sections[0].content else { return XCTFail() }
        XCTAssertEqual(night.asleepMin, 412)
        XCTAssertEqual(usual, 438)
        guard case .recovery(let r) = digest.sections[1].content else { return XCTFail() }
        XCTAssertEqual(r.level, "good")
        XCTAssertEqual(r.restingHrUsual, 54)
    }

    func testSleepCardWording() {
        XCTAssertEqual(SleepCard.duration(412), "6h 52m")
        XCTAssertEqual(SleepCard.duration(45), "45m")
        XCTAssertEqual(SleepCard.compare(400, 440), "40m under your usual 7h 20m")
        XCTAssertEqual(SleepCard.compare(445, 440), "About your usual")
    }

    func testHabitWithoutWorkoutsFromOlderServer() throws {
        let json = #"{"id":3,"name":"Gym","cadence":{"type":"daily"},"streak":0,"done_today":false,"last_done":null}"#
        XCTAssertNil(try JSONDecoder.api.decode(Habit.self, from: Data(json.utf8)).workouts)
    }
}

final class AgentTests: XCTestCase {
    func testEachKnownAgentHasItsOwnFigure() {
        XCTAssertEqual(Figure(agent: "aide"), .pebble)
        XCTAssertEqual(Figure(agent: "coach"), .ball)
        XCTAssertEqual(Figure(agent: "someone-new"), .pebble) // an agent the app doesn't know yet
        XCTAssertEqual(Figure(agent: nil), .pebble)
        // Every figure fits its tile at the live size (scaled 1.2 about the centre).
        for figure in [Figure.pebble, .card, .dome, .ball, .ingot] {
            let box = figure.body.boundingRect
            XCTAssertGreaterThanOrEqual((box.minX - 128) * 1.2 + 128, 0, "\(figure)")
            XCTAssertLessThanOrEqual((box.maxX - 128) * 1.2 + 128, 256, "\(figure)")
            XCTAssertGreaterThanOrEqual((box.minY - 128) * 1.2 + 128, 0, "\(figure)")
            XCTAssertLessThanOrEqual((box.maxY - 128) * 1.2 + 128, 256, "\(figure)")
        }
    }

    func testAgentsDecodeWithDefaults() throws {
        let json = #"""
        {"agents":[{"id":"aide","name":"Aide","role":"Talks to all of them","color":"#34413F","orchestrator":true,"starters":["Remind me to "]},
                   {"id":"coach","name":"Coach","color":"#E0782F"}]}
        """#
        let agents = try JSONDecoder.api.decode(AgentList.self, from: Data(json.utf8)).agents
        XCTAssertTrue(agents[0].orchestrator)
        XCTAssertFalse(agents[1].orchestrator)
        XCTAssertEqual(agents[1].starters, [])
        XCTAssertEqual(agents[1].role, "")
        XCTAssertEqual(agents[1].hex, 0xE0782F)
        XCTAssertNil(Agent(id: "x", name: "X", role: "", color: "orange", orchestrator: false, starters: []).hex)
        XCTAssertEqual(agents[1].prompt, "")
        XCTAssertEqual(agents[1].connectors, [])
    }

    func testAgentsDecodeTheirPromptAndConnectors() throws {
        let json = #"""
        {"agents":[{"id":"coach","name":"Coach","color":"#23A26D","prompt":"You are Coach.","tools":["health","list_events"],
                    "connectors":[{"id":"calendar","name":"iCloud Calendar","read_only":true,"tools":["list_events"]}]}]}
        """#
        let coach = try JSONDecoder.api.decode(AgentList.self, from: Data(json.utf8)).agents[0]
        XCTAssertEqual(coach.prompt, "You are Coach.")
        XCTAssertEqual(coach.tools, ["health", "list_events"])
        XCTAssertEqual(coach.connectors, [.init(id: "calendar", name: "iCloud Calendar", readOnly: true, tools: ["list_events"])])
    }
}

final class VoiceTests: XCTestCase {
    @MainActor func testRepliesAreReadOutInWholeSentences() {
        func spoken(_ s: String) -> String? { VoiceController.lastSentenceEnd(in: s[...]).map { String(s[..<$0]) } }
        XCTAssertNil(spoken("Your next class is at 10"))
        XCTAssertNil(spoken("Your next class is at 10.")) // the space after it hasn't arrived yet
        XCTAssertNil(spoken("At 10.30 you"))
        XCTAssertEqual(spoken("Sleep was short. Go easy. Tomor"), "Sleep was short. Go easy.")
        XCTAssertEqual(spoken("Today:\n- gym"), "Today:\n")
    }

    func testRecordingsAreSentAsWAV() {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let wav = PCMRecorder.wav(pcm)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func le32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        XCTAssertEqual(le32(4), UInt32(36 + pcm.count))
        XCTAssertEqual(le32(24), 16_000) // sample rate
        XCTAssertEqual(le32(28), 32_000) // bytes a second: mono, 16-bit
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(le32(40), UInt32(pcm.count))
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
    }

    func testConsultedAndAgentFieldsDefault() throws {
        let reply = try JSONDecoder.api.decode(ChatReply.self, from: Data(#"{"reply":"ok","consulted":["coach"]}"#.utf8))
        XCTAssertEqual(reply.consulted, ["coach"])
        let old = try JSONDecoder.api.decode(ChatReply.self, from: Data(#"{"reply":"ok"}"#.utf8))
        XCTAssertEqual(old.consulted, [])
        XCTAssertEqual(old.team, [])
        let h = try JSONDecoder.api.decode(HistoryMessage.self, from: Data(
            #"{"role":"assistant","text":"ok","team":[{"from":"aide","to":"coach","text":"?","ts":"2026-10-19T18:02:11+02:00"}]}"#.utf8))
        XCTAssertEqual(h.team.first?.to, "coach")
        let t = try JSONDecoder.api.decode(TeamList.self, from: Data(
            #"{"messages":[{"from":"coach","to":"aide","text":"!","conversation_id":"c_9"}]}"#.utf8))
        XCTAssertEqual(t.messages.first?.conversationId, "c_9")
        let c = try JSONDecoder.api.decode(Conversation.self, from: Data(#"{"id":"c_1","title":null}"#.utf8))
        XCTAssertNil(c.agent)
        let m = try JSONDecoder.api.decode(MemoryItem.self, from: Data(#"{"id":7,"text":"Vegetarian","agent":"coach"}"#.utf8))
        XCTAssertEqual(m.agent, "coach")
    }

    func testRoutinesDecodeAndLabel() throws {
        let r = try JSONDecoder.api.decode(Routine.self, from: Data(#"""
        {"id": 3, "agent": "coach", "title": "Weekly recap", "prompt": "Recap", "time": "18:00", "days": [7],
         "enabled": true, "conversation_id": "c_7", "next_run": "2026-10-25T18:00:00+02:00", "last_run": null}
        """#.utf8))
        XCTAssertEqual(r.conversationId, "c_7")
        XCTAssertNil(r.lastRun)
        let agent = try JSONDecoder.api.decode(Agent.self, from: Data(
            #"{"id":"coach","name":"Coach","routine_ideas":[{"title":"Weekly recap","prompt":"Recap","days":[7]}]}"#.utf8))
        XCTAssertEqual(agent.routineIdeas.first?.time, "09:00")
        let c = try JSONDecoder.api.decode(Conversation.self, from: Data(#"{"id":"c_7","title":"Weekly recap","routine":3}"#.utf8))
        XCTAssertEqual(c.routine, 3)
        let h = try JSONDecoder.api.decode(HistoryMessage.self, from: Data(
            #"{"role":"assistant","text":"Recap…","routine":{"id":3,"title":"Weekly recap"}}"#.utf8))
        XCTAssertEqual(h.routine?.title, "Weekly recap")
        // A change leaves `agent` out.
        let patch = String(decoding: try JSONEncoder.api.encode(
            RoutineDraft(title: "T", prompt: "P", time: "09:00", days: [], enabled: false)), as: UTF8.self)
        XCTAssertFalse(patch.contains("agent"))

        XCTAssertEqual(Schedule.label(time: "09:00", days: []), "Every day at 09:00")
        XCTAssertEqual(Schedule.label(time: "09:00", days: [1, 2, 3, 4, 5]), "Weekdays at 09:00")
        XCTAssertEqual(Schedule.label(time: "10:00", days: [6, 7]), "Weekends at 10:00")
        XCTAssertEqual(Schedule.label(time: "18:00", days: [7]), "Sundays at 18:00")
        XCTAssertEqual(Schedule.label(time: "07:30", days: [5, 1, 3]), "Mon, Wed, and Fri at 07:30")
        XCTAssertEqual(RoutineEditor.string(from: RoutineEditor.date(from: "07:05")), "07:05")
    }

    func testWatchesDecodeAndOlderServersHaveNone() throws {
        let old = try JSONDecoder.api.decode(Routine.self, from: Data(
            #"{"id":3,"agent":"coach","title":"Recap","prompt":"P","time":"18:00","days":[],"enabled":true}"#.utf8))
        XCTAssertFalse(old.isWatch)
        let watch = try JSONDecoder.api.decode(Routine.self, from: Data(
            #"{"id":4,"agent":"coach","title":"Recovery","prompt":"P","time":"09:00","days":[],"enabled":true,"watch":true}"#.utf8))
        XCTAssertTrue(watch.isWatch)
        let agent = try JSONDecoder.api.decode(Agent.self, from: Data(
            #"{"id":"coach","name":"Coach","routine_ideas":[{"title":"A","prompt":"P"},{"title":"B","prompt":"P","watch":true}]}"#.utf8))
        XCTAssertEqual(agent.routineIdeas.map(\.watch), [false, true])
        let silent = try JSONDecoder.api.decode(RoutineRun.self, from: Data(#"""
        {"routine": {"id":4,"agent":"coach","title":"Recovery","prompt":"P","time":"09:00","days":[],"enabled":true,"watch":true},
         "conversation_id": "c_4", "spoke": false}
        """#.utf8))
        XCTAssertEqual(silent.spoke, false)
        let draft = String(decoding: try JSONEncoder.api.encode(
            RoutineDraft(title: "T", prompt: "P", time: "09:00", days: [], enabled: true, watch: true)), as: UTF8.self)
        XCTAssertTrue(draft.contains(#""watch":true"#))
    }

    func testNewConversationSendsAgentOnlyWhenSet() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder.api.encode(NewConversation()), as: UTF8.self), "{}")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(NewConversation(agent: "coach"))) as? [String: Any])
        XCTAssertEqual(obj["agent"] as? String, "coach")
    }
}

final class FoodTests: XCTestCase {
    private let meal = #"""
    {"id":12,"name":"Pasta al pomodoro","eaten_at":"2026-10-21T13:10:00+02:00","calories":650,
     "protein_g":20,"carbs_g":110.0,"fat_g":15,"photo":"p_3f9a","notes":"about 120 g dry pasta"}
    """#

    func testMealDecodes() throws {
        let m = try JSONDecoder.api.decode(Meal.self, from: Data(meal.utf8))
        XCTAssertEqual(m.id, 12)
        XCTAssertEqual(m.name, "Pasta al pomodoro")
        XCTAssertEqual(m.calories, 650)
        XCTAssertEqual(m.carbsG, 110) // a whole number sent as 110.0
        XCTAssertEqual(m.photo, "p_3f9a")
        XCTAssertNotNil(m.eatenDate)
        XCTAssertEqual(MealRow.macros(m), "P 20 g · C 110 g · F 15 g")
    }

    func testFoodDayWithoutGoalsAndMealWithoutPhoto() throws {
        let json = #"""
        {"date":"2026-10-21","meals":[{"id":1,"name":"Apple","eaten_at":"2026-10-21T10:00:00+02:00","calories":80,
          "protein_g":0,"carbs_g":21,"fat_g":0,"photo":null,"notes":""}],
         "totals":{"calories":80,"protein_g":0,"carbs_g":21,"fat_g":0},
         "goals":{"calories":null,"protein_g":140,"carbs_g":null,"fat_g":null}}
        """#
        let day = try JSONDecoder.api.decode(FoodDay.self, from: Data(json.utf8))
        XCTAssertEqual(day.meals.count, 1)
        XCTAssertNil(day.meals[0].photo)
        XCTAssertEqual(day.totals.carbsG, 21)
        XCTAssertNil(day.goals.calories)
        XCTAssertEqual(day.goals.proteinG, 140)
    }

    func testGoalsSaveEveryKeySoClearingSendsNull() throws {
        let data = try JSONEncoder.api.encode(FoodGoals(calories: 2200))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["calories"] as? Int, 2200)
        XCTAssertTrue(obj["protein_g"] is NSNull)
        XCTAssertTrue(obj["fat_g"] is NSNull)
    }

    func testFoodDaysDecode() throws {
        let json = #"""
        {"days":[{"date":"2026-10-20","totals":{"calories":0,"protein_g":0,"carbs_g":0,"fat_g":0},"meals":0},
                 {"date":"2026-10-21","totals":{"calories":1840,"protein_g":96,"carbs_g":210,"fat_g":61},"meals":3}]}
        """#
        let days = try JSONDecoder.api.decode(FoodDayList.self, from: Data(json.utf8)).days
        XCTAssertEqual(days.map(\.date), ["2026-10-20", "2026-10-21"])
        XCTAssertEqual(days[1].meals, 3)
        XCTAssertEqual(days[1].totals.calories, 1840)
    }

    func testMealsAttachmentAndUnknownOnesSkipped() throws {
        let json = #"{"reply":"Logged.","attachments":[{"type":"meals","meals":[\#(meal)]},{"type":"places","places":[]}]}"#
        let reply = try JSONDecoder.api.decode(ChatReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.attachments.count, 1)
        guard case .meals(let meals) = reply.attachments[0] else { return XCTFail("expected meals") }
        XCTAssertEqual(meals.first?.name, "Pasta al pomodoro")
    }

    func testHistoryCarriesPhotos() throws {
        let json = #"""
        {"messages":[{"role":"user","text":"","photos":["p_1","p_2"]},{"role":"assistant","text":"Nice pasta."}]}
        """#
        let history = try JSONDecoder.api.decode(HistoryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(history.messages[0].photos, ["p_1", "p_2"])
        XCTAssertEqual(history.messages[1].photos, [])
    }

    func testChatSendsPhotosOnlyWhenThereAreSome() throws {
        let with = try JSONEncoder.api.encode(ChatRequest(text: "", photos: ["p_1"]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: with) as? [String: Any])?["photos"] as? [String], ["p_1"])
        let without = try JSONEncoder.api.encode(ChatRequest(text: "hi"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: without) as? [String: Any])?["photos"])
    }

    func testFoodLogLeavesOutTodayAndText() throws {
        let data = try JSONEncoder.api.encode(FoodLogRequest(photos: ["p_1"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["photos"] as? [String], ["p_1"])
        XCTAssertNil(obj["date"])
        XCTAssertNil(obj["text"])
    }

    func testPhotosShrinkToTheLongestSide() throws {
        XCTAssertEqual(PhotoPrep.fitted(CGSize(width: 4000, height: 3000)), CGSize(width: 1568, height: 1176))
        XCTAssertEqual(PhotoPrep.fitted(CGSize(width: 3000, height: 4000)), CGSize(width: 1176, height: 1568))
        XCTAssertEqual(PhotoPrep.fitted(CGSize(width: 800, height: 600)), CGSize(width: 800, height: 600))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let fromCamera = try XCTUnwrap(PhotoPrep.jpeg(big).flatMap(UIImage.init(data:)))
        XCTAssertEqual(fromCamera.size.width * fromCamera.scale, 1568)
        XCTAssertEqual(fromCamera.size.height * fromCamera.scale, 1176)

        let fromLibrary = try XCTUnwrap(big.pngData().flatMap(PhotoPrep.jpeg).flatMap(UIImage.init(data:)))
        XCTAssertEqual(max(fromLibrary.size.width, fromLibrary.size.height) * fromLibrary.scale, 1568)
    }
}

@MainActor
final class PhotoAPITests: XCTestCase {
    func testUploadSendsJPEGAndKeepsItForShowing() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(session: URLSession(configuration: cfg),
                            config: { APIConfig(baseURL: URL(string: "https://aide.test")!, token: "secret") })
        var seen: [URLRequest] = []
        StubURLProtocol.handler = { seen.append($0); return (200, #"{"id":"p_9"}"#) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let id = try await api.uploadPhoto(jpeg)
        XCTAssertEqual(id, "p_9")
        XCTAssertEqual(seen.first?.url?.path, "/v1/photos")
        XCTAssertEqual(seen.first?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        let shown = try await api.photo("p_9")
        XCTAssertEqual(shown, jpeg)
        XCTAssertEqual(seen.count, 1) // from memory, no download
    }
}
