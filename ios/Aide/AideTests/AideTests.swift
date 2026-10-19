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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
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
    }

    func testConsultedAndAgentFieldsDefault() throws {
        let reply = try JSONDecoder.api.decode(ChatReply.self, from: Data(#"{"reply":"ok","consulted":["coach"]}"#.utf8))
        XCTAssertEqual(reply.consulted, ["coach"])
        let old = try JSONDecoder.api.decode(ChatReply.self, from: Data(#"{"reply":"ok"}"#.utf8))
        XCTAssertEqual(old.consulted, [])
        let c = try JSONDecoder.api.decode(Conversation.self, from: Data(#"{"id":"c_1","title":null}"#.utf8))
        XCTAssertNil(c.agent)
        let m = try JSONDecoder.api.decode(MemoryItem.self, from: Data(#"{"id":7,"text":"Vegetarian","agent":"coach"}"#.utf8))
        XCTAssertEqual(m.agent, "coach")
    }

    func testNewConversationSendsAgentOnlyWhenSet() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder.api.encode(NewConversation()), as: UTF8.self), "{}")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(NewConversation(agent: "coach"))) as? [String: Any])
        XCTAssertEqual(obj["agent"] as? String, "coach")
    }
}
