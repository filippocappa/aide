import AVFoundation
import SwiftUI
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

    func testApprovalsDecode() throws {
        let json = #"""
        {"waiting": 3,
         "actions": [{"id": 42, "summary": "Delete reminder 'Bins'", "agent": "secretary", "conversation_id": "main",
                      "created_at": "2026-10-22T18:00:00+02:00", "expires_at": "2026-10-22T18:30:00+02:00"}],
         "objectives": [{"id": "o1", "agent": "coach", "period": "week", "start": "2026-10-19", "end": "2026-10-25",
                         "title": "Run 3 times", "why": null, "measure": {"type": "habit", "habit": 4, "label": "check-ins of Run"},
                         "progress": 1, "target": 3, "done": false, "status": "proposed", "parent": null, "added_by": "coach"}],
         "proposals": [{"id": "p1", "kind": "update", "status": "pending", "course": 2, "course_name": "Macroeconomics",
                        "conversation_id": "c9", "items": []}],
         "drafts": [{"id": 3, "message_id": "m1", "thread_id": "t1", "from": "Anna Bianchi",
                     "from_address": "anna@example.com", "subject": "Dinner Friday?", "preview": "Are you free?",
                     "received_at": "2026-10-22T18:02:00+02:00", "why": "Anna asks about Friday", "body": "Yes!",
                     "status": "waiting", "agent": "secretary", "created_at": "2026-10-22T21:55:10+02:00"}],
         "writer": null,
         "upcoming": [{"id": 1, "agent": "secretary", "title": "Tomorrow", "prompt": "p", "time": "20:00", "days": [],
                       "enabled": true, "watch": true, "conversation_id": "c3", "next_run": "2026-10-22T20:00:00+02:00",
                       "last_run": null}]}
        """#
        let a = try JSONDecoder.api.decode(Approvals.self, from: Data(json.utf8))
        XCTAssertEqual(a.waiting, 3)
        XCTAssertEqual(a.actions.first?.agent, "secretary")
        XCTAssertNotNil(a.actions.first?.expiresAt.flatMap(Wire.parse))
        XCTAssertTrue(a.objectives.first?.isProposed == true)
        XCTAssertEqual(a.proposals.first?.courseName, "Macroeconomics")
        XCTAssertEqual(a.proposals.first?.conversationId, "c9")
        XCTAssertNil(a.writer)
        XCTAssertTrue(a.upcoming.first?.isWatch == true)
        let draft = try XCTUnwrap(a.drafts?.first)
        XCTAssertEqual(draft.fromAddress, "anna@example.com")
        XCTAssertEqual(draft.detail, "Dinner Friday? · Anna asks about Friday")
        XCTAssertEqual(draft.replySubject, "Re: Dinner Friday?")
        // An older server has no drafts.
        let old = try JSONDecoder.api.decode(Approvals.self, from: Data(
            #"{"waiting": 0, "actions": [], "objectives": [], "proposals": [], "writer": null, "upcoming": []}"#.utf8))
        XCTAssertNil(old.drafts)
    }

    func testDigestRepliesSectionDecodes() throws {
        let json = #"""
        {"kind": "evening", "generated_at": "2026-10-22T22:00:00+02:00", "greeting": "Night.",
         "sections": [{"type": "replies", "title": "Replies to send", "drafts": [
           {"id": 3, "from": "Anna Bianchi", "from_address": null, "subject": "Re: Dinner", "preview": "",
            "received_at": null, "why": null, "body": "Yes!", "agent": "secretary"}]}]}
        """#
        let d = try JSONDecoder.api.decode(Digest.self, from: Data(json.utf8))
        guard case .replies(let drafts) = d.sections.first?.content else { return XCTFail("not replies") }
        XCTAssertEqual(drafts.first?.replySubject, "Re: Dinner")
        XCTAssertEqual(drafts.first?.detail, "Re: Dinner")
    }

    func testNotebookPracticeDecodes() throws {
        let nb = try JSONDecoder.api.decode(NotebookStatus.self, from: Data(
            #"{"course": 2, "started": true, "busy": false, "topics": [], "proposals": [], "formulas": 3, "exercises": 2}"#.utf8))
        XCTAssertEqual(nb.formulas, 3)
        XCTAssertEqual(nb.exercises, 2)
        let old = try JSONDecoder.api.decode(NotebookStatus.self, from: Data(#"{"course": 2, "started": true}"#.utf8))
        XCTAssertNil(old.exercises)
        let json = #"""
        {"course": 2, "sets": [{"id": "e_1", "course": 2, "topic": {"id": "t_1", "title": "The IS-LM model"},
          "count": 8, "from_material": 3, "new": 5, "checked": true, "updated_at": "2026-10-29T10:00:00+01:00"}]}
        """#
        let set = try XCTUnwrap(JSONDecoder.api.decode(ExerciseSetList.self, from: Data(json.utf8)).sets.first)
        XCTAssertEqual(set.topic.title, "The IS-LM model")
        XCTAssertEqual(set.fromMaterial, 3)
        XCTAssertNil(set.body)
        let body = try JSONEncoder.api.encode(ExercisesBody(topics: nil))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{}")
    }

    func testMockExamsDecodeAndOpenAnswersEncode() throws {
        let list = #"""
        {"course": 2, "mocks": [{"id": "m_1", "course": 2, "number": 1, "title": "Mock exam 1", "minutes": 90,
          "scoring": {"right": 1, "wrong": 0, "blank": 0}, "count": 16, "mcq": 15, "open": 1, "points": 30,
          "created_at": "2026-10-29T10:00:00+01:00", "taken": 1, "best": 24.5, "last": null},
         {"id": "m_2", "course": 2, "number": 1, "title": "Mock exam 2026", "source": {"id": "f_1",
          "name": "Example Questions Midterm.pdf"}, "minutes": null, "scoring": {"right": 1, "wrong": -0.25,
          "blank": 0}, "count": 30, "mcq": 30, "open": 0, "points": 30, "taken": 0, "best": null}]}
        """#
        let mocks = try JSONDecoder.api.decode(MockExamList.self, from: Data(list.utf8)).mocks
        let mock = try XCTUnwrap(mocks.first)
        XCTAssertNil(mock.source)
        XCTAssertEqual(mocks.last?.source?.name, "Example Questions Midterm.pdf")
        XCTAssertEqual(mock.open, 1)
        XCTAssertEqual(mock.best, 24.5)
        XCTAssertTrue(PracticeExamView.rules(mock).contains("no penalty"))
        let quiz = #"""
        {"id": "x_1", "kind": "mock", "mock": "m_1", "scoring": {"right": 1, "wrong": 0, "blank": 0}, "course": 2,
         "minutes": 90, "count": 1, "finished_at": "2026-10-29T11:00:00+01:00",
         "score": {"points": 1, "max": 16, "right": 1, "wrong": 0, "blank": 0, "grading": true},
         "questions": [{"n": 16, "topic": {"id": "", "title": "The course"}, "text": "Explain.", "options": [],
           "type": "open", "points": 15, "answer": null, "response": {"text": "I would", "photos": ["p_1"]},
           "awarded": null, "feedback": null, "correct": false, "model_answer": "All of it", "rubric": "- 15: all"}]}
        """#
        let taken = try JSONDecoder.api.decode(Quiz.self, from: Data(quiz.utf8))
        XCTAssertEqual(taken.score?.grading, true)
        let open = try XCTUnwrap(taken.questions.first)
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(open.response?.photos, ["p_1"])
        XCTAssertEqual(open.modelAnswer, "All of it")
        let body = try JSONEncoder.api.encode(QuizFinishBody(answers: ["1": .letter("B"),
                                                                        "16": .open(text: "I would", photos: ["p_1"])]))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String: Any]])
        XCTAssertEqual(decoded["answers"]?["1"] as? String, "B")
        XCTAssertEqual((decoded["answers"]?["16"] as? [String: Any])?["photos"] as? [String], ["p_1"])
        let start = try JSONEncoder.api.encode(QuizStartBody(course: 2, mock: "m_1"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: start) as? [String: AnyHashable], ["course": 2, "mock": "m_1"])
    }

    func testActivityPagesAndGroupsByDay() throws {
        let json = #"""
        {"items": [
          {"id": 3, "ts": "2026-10-22T18:00:00+02:00", "agent": "coach", "kind": "action", "title": "Logged a meal",
           "detail": "Pasta", "conversation_id": "c1"},
          {"id": 2, "ts": "2026-10-22T08:00:00+02:00", "agent": "aide", "kind": "digest", "title": "Morning digest",
           "detail": null, "conversation_id": null},
          {"id": 1, "ts": "2026-10-21T21:00:00+02:00", "agent": "secretary", "kind": "something_new", "title": "New"}],
         "next": 1}
        """#
        let page = try JSONDecoder.api.decode(ActivityPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.next, 1)
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        let days = ActivityDays.group(page.items, calendar: rome)
        XCTAssertEqual(days.map { $0.items.map(\.id) }, [[3, 2], [1]])
        XCTAssertEqual(ActivityRow.symbol("something_new"), "circle.fill") // an unknown kind still shows
        XCTAssertEqual(ActivityRow.verb("queued"), "Asked to")
    }

    func testActionIDsEncode() throws {
        let data = try JSONEncoder.api.encode(ActionIDs(ids: [42, 43]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ids":[42,43]}"#)
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

final class NoteTextTests: XCTestCase {
    func testFormulasInTheNotesAreDrawn() throws {
        let notes = #"""
        Nominal GDP:
        $$Y^{nom}_t=\sum_i P_{i,t}\,Q_{i,t}$$
        > [!success]- Solution
        > $$
        > x=\dfrac{1}{2}
        > $$.
        """#
        let blocks = NoteText.parse(notes)
        guard blocks.count == 3, case .paragraph("Nominal GDP:") = blocks[0], case .math(let gdp) = blocks[1],
              case .callout(_, _, _, let solution) = blocks[2], NoteText.parse(solution).count == 1,
              case .math(let half) = NoteText.parse(solution)[0]
        else { return XCTFail("\(blocks)") }
        XCTAssertEqual(gdp, #"Y^{nom}_t=\sum_i P_{i,t}\,Q_{i,t}"#)
        XCTAssertEqual(half, #"x=\dfrac{1}{2}"#)

        // What the live notes write that SwiftMath doesn't read as it is.
        for latex in [#"L = \tfrac{1}{2}\left[\beta(\pi - \pi^T)^2 + (y - \bar y)^2\right]"#,
                      #"a_1 x_1 + \dots + a_n x_n = b"#, half,
                      #"\begin{cases} -x + 2y = 4 \\ 2x - y = 1 \end{cases}"#,
                      #"\left\{ \sum_{i=1}^t k_i \underline{w}^i \;\middle|\; k_i \in \mathbb{R} \right\}"#] {
            XCTAssertNil(MathFormula.mathList(latex), latex)
            XCTAssertNotNil(MathFormula.mathList(MathFormula.prepare(latex)), latex)
        }
        XCTAssertEqual(MathFormula.prepare(#"\begin{cases} a \\ b & c \end{cases}"#), #"\begin{cases} a  &\\ b & c \end{cases}"#)
    }

    /// A `+` after a comma and a space stopped SwiftMath's typesetter (an assert, so the app crashed in debug builds).
    @MainActor func testAPlusAfterACommaAndASpaceIsDrawn() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        window.rootViewController = UIHostingController(rootView: VStack {
            MathFormula(latex: #"Y=C(Y-T)+I(Y,\,r+x),\;+G,\qquad r=\bar r"#)
            MathFormula(latex: #"\left(\;-x,\; -\frac{a}{b}\;\right) = \;- 1"#)
        })
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.isHidden = true
    }

    /// Contents lists the headings down to `###`, with the ids the page's headings get.
    func testContentsListsTheHeadings() {
        let notes = """
        # Macroeconomics
        Intro.
        ## GDP and \\(Y_t\\)
        - a point
        ### Real GDP
        #### Too deep
        > [!info] Inside a callout
        > ## Not listed
        """
        let headings = NoteText.headings(notes)
        XCTAssertEqual(headings.map(\.title), ["Macroeconomics", "GDP and \\(Y_t\\)", "Real GDP"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(Set(headings.map(\.id)).count, 3)
        XCTAssertEqual(headings[0].id, "heading-0")
    }

    /// Maths inside a sentence (`\(…\)` from `inline=true`) is drawn, the markdown around it kept; what SwiftMath
    /// can't read stays as its LaTeX.
    @MainActor func testInlineMathsIsDrawn() throws {
        XCTAssertNotNil(MathFormula.mathList(MathFormula.prepare(#"\big(1+r\big)\Bigl[x\Bigr]"#)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        window.rootViewController = UIHostingController(rootView: NoteText(markdown: #"""
        ## Prices \(P_{i,t}\)
        **Nominal** GDP \(Y^{nom}_t=\sum_i P_{i,t}\,Q_{i,t}\) at current prices, \(\frac{a}{b}\), and \(\oops{x}\).
        - \(\pi_t - \pi_{t-1} = -\alpha(u_t - u_n)\)
        """#, anchored: true))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.isHidden = true
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
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "moodle", "files": ["f_1", "f_2"]]]),
                       .moodle(login: false, files: ["f_1", "f_2"]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "sync"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "test"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "something-new"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "message"]]))
        XCTAssertNil(PushRoute(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertTrue(PushRoute.isSync(["aps": ["content-available": 1], "aide": ["kind": "sync"]]))
        XCTAssertFalse(PushRoute.isSync(["aide": ["kind": "digest"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "location"]]))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "transit", "alert_id": 3]])) // opens the app, nothing more
        XCTAssertTrue(PushRoute.isLocation(["aps": ["content-available": 1], "aide": ["kind": "location"]]))
        XCTAssertFalse(PushRoute.isLocation(["aide": ["kind": "sync"]]))
    }

    func testWidgetAndLiveActivityLinksRoute() {
        XCTAssertEqual(PushRoute(url: URL(string: "aide://conversation/c_91f")!), .conversation("c_91f"))
        XCTAssertEqual(PushRoute(url: URL(string: "aide://agent/coach")!), .agent("coach"))
        XCTAssertEqual(PushRoute(url: URL(string: "aide://team")!), .team)
        XCTAssertEqual(PushRoute(url: URL(string: "aide://meal/describe")!), .meal(.describe))
        XCTAssertEqual(PushRoute(url: URL(string: "aide://meal")!), .meal(.photo))
        XCTAssertEqual(PushRoute(url: URL(string: "aide://voice")!), .voice)
        XCTAssertEqual(PushRoute(url: URL(string: "aide://today")!), .today)
        XCTAssertEqual(PushRoute(url: URL(string: "aide://objectives")!), .objectives)
        XCTAssertEqual(PushRoute(url: URL(string: "aide://health")!), .health)
        XCTAssertNil(PushRoute(url: URL(string: "aide://agent")!))
        XCTAssertNil(PushRoute(url: URL(string: "aide://something-new")!))
        XCTAssertNil(PushRoute(url: URL(string: "https://example.com/team")!))
    }

    /// The server's push payloads, as in docs/API.md, "Live Activities": ActivityKit decodes them with a plain decoder.
    func testLiveActivityStatesDecodeFromTheServersJSON() throws {
        let tram = """
        {"at": 1792483800, "leave": 1792483380, "walk": 300, "live": true, "delay": 60, "next": 1792484400, "gone": false}
        """
        let t = try JSONDecoder().decode(TramActivityAttributes.ContentState.self, from: Data(tram.utf8))
        XCTAssertEqual(t.atDate, Date(timeIntervalSince1970: 1792483800))
        XCTAssertEqual(t.leaveDate, Date(timeIntervalSince1970: 1792483380))
        XCTAssertEqual(t.walk, 300)
        XCTAssertNil(t.stops)
        let placed = """
        {"at": 1792483800, "live": false, "gone": false, "stops": 8, "near": "Statuto Cap", "starts": 1792483300,
         "feed_down": true}
        """
        let p = try JSONDecoder().decode(TramActivityAttributes.ContentState.self, from: Data(placed.utf8))
        XCTAssertEqual(p.stops, 8)
        XCTAssertEqual(p.near, "Statuto Cap")
        XCTAssertEqual(p.startsDate, Date(timeIntervalSince1970: 1792483300))
        XCTAssertEqual(p.feedDown, true)
        XCTAssertFalse(p.isRiding)
        XCTAssertNil(p.atStop)
        let riding = """
        {"at": 1792485000, "leave": null, "walk": null, "live": true, "delay": null, "next": null, "gone": false,
         "stops": 2, "near": "Statuto Cap", "starts": null, "feed_down": false, "at_stop": false, "riding": true,
         "to": "Porta Susa"}
        """
        let r = try JSONDecoder().decode(TramActivityAttributes.ContentState.self, from: Data(riding.utf8))
        XCTAssertTrue(r.isRiding)
        XCTAssertEqual(r.to, "Porta Susa")
        XCTAssertEqual(r.atStop, false)
        let bare = #"{"at": 1792483800, "live": false, "gone": true}"#
        let b = try JSONDecoder().decode(TramActivityAttributes.ContentState.self, from: Data(bare.utf8))
        XCTAssertNil(b.leaveDate)
        XCTAssertNil(b.nextDate)
        XCTAssertTrue(b.gone)

        let attrs = """
        {"key": "agent:c_91f", "agent": "coach", "name": "Coach", "color": "#1F8A5B", "conversation": "c_91f"}
        """
        let a = try JSONDecoder().decode(AgentActivityAttributes.self, from: Data(attrs.utf8))
        XCTAssertNil(a.title)
        XCTAssertEqual(a.url, URL(string: "aide://conversation/c_91f"))
        let state = #"{"status": "done", "detail": "", "text": "Logged it.", "since": 1792483800}"#
        let s = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(state.utf8))
        XCTAssertTrue(s.isOver)
        XCTAssertEqual(s.line(name: "Coach"), "Logged it.")
        XCTAssertEqual(AgentActivityAttributes.ContentState.working().line(name: "Coach"), "Coach is working on it")
        XCTAssertNil(s.total)
        let notes = #"{"status": "writing", "detail": "Writing Crowding out", "text": "", "since": 1, "done": 2, "total": 5}"#
        let n = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(notes.utf8))
        XCTAssertEqual(n.done, 2)
        XCTAssertEqual(n.total, 5)
        XCTAssertEqual(n.line(name: "Professor"), "Writing Crowding out")
    }

    func testEventActivityDecodes() throws {
        let attrs = #"{"key": "event:3f2a9c1b7d4e:1792483800", "title": "Macroeconomics", "calendar": "Timetable"}"#
        let a = try JSONDecoder().decode(EventActivityAttributes.self, from: Data(attrs.utf8))
        XCTAssertEqual(a.title, "Macroeconomics")
        let state = #"{"start": 1792483800, "end": null, "place": "Aula 5", "started": false}"#
        let s = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data(state.utf8))
        XCTAssertEqual(s.startDate, Date(timeIntervalSince1970: 1792483800))
        XCTAssertNil(s.endDate)
        XCTAssertEqual(s.place, "Aula 5")
        XCTAssertNil(s.since)
        XCTAssertNil(s.then)
        XCTAssertNil(s.length)
        let full = #"{"start": 1792483800, "end": 1792489200, "place": "Aula 5", "started": false, "since": 1792483200, "notes": "Bring the problem set", "then": {"title": "Gym", "start": 1792494600}}"#
        let f = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data(full.utf8))
        XCTAssertEqual(f.sinceDate, Date(timeIntervalSince1970: 1792483200))
        XCTAssertEqual(f.notes, "Bring the problem set")
        XCTAssertEqual(f.then?.title, "Gym")
        XCTAssertEqual(f.length, "1 h 30")
    }

    func testNearbyBoardsDecode() throws {
        let json = """
        {"boards": [{"id": "1687", "stop": {"id": "1687", "code": "253", "name": "Porta Nuova"}, "at": "2026-10-24T08:00:00+02:00",
          "distance": 120, "walk": 95, "line": null, "to": null,
          "lines": [{"line": "4", "vehicle": "Tram", "towards": "Falchera",
                     "arrivals": [{"at": "2026-10-24T08:04:00+02:00", "scheduled": "2026-10-24T08:03:00+02:00", "live": true, "delay": 60}]}]}],
         "fix_at": "2026-10-24T07:58:00+02:00"}
        """
        let n = try JSONDecoder.api.decode(NearbyBoards.self, from: Data(json.utf8))
        XCTAssertEqual(n.fixAt, "2026-10-24T07:58:00+02:00")
        XCTAssertEqual(n.boards.first?.lines.first?.arrivals.first?.delay, 60)
    }

    func testTransitAlertDecodesAndReads() throws {
        let json = """
        {"id": 1, "line": "4", "vehicle": "Tram", "towards": ["Falchera"],
         "stop": {"id": "1687", "code": "253", "name": "Porta Nuova"}, "time": "08:10", "days": [1, 2, 3, 4, 5],
         "once": false, "minutes": null, "enabled": true, "summary": "Tram 4 at Porta Nuova"}
        """
        let a = try JSONDecoder.api.decode(TransitAlert.self, from: Data(json.utf8))
        XCTAssertEqual(a.title, "Tram 4 → Falchera")
        XCTAssertEqual(a.stopLabel, "Porta Nuova · stop 253")
        XCTAssertEqual(a.when, "Weekdays around 08:10")
        XCTAssertEqual(a.lead, "When it's time to leave")
        let once = """
        {"id": 2, "line": "15", "vehicle": "Tram", "towards": [], "stop": {"id": "1", "code": "1", "name": "X"},
         "time": null, "days": null, "once": true, "minutes": 10, "enabled": true, "summary": ""}
        """
        let b = try JSONDecoder.api.decode(TransitAlert.self, from: Data(once.utf8))
        XCTAssertEqual(b.title, "Tram 15")
        XCTAssertEqual(b.when, "Once, the next one")
        XCTAssertEqual(b.lead, "10 min before")
    }

    func testDeparturesAttachmentDecodes() throws {
        let json = """
        [{"type": "departures", "departures": [{
          "id": "1687:4:Politecnico", "stop": {"id": "1687", "code": "253", "name": "Porta Nuova"},
          "at": "2026-10-22T06:00:00Z", "distance": 180, "walk": 170, "line": "4",
          "to": {"name": "Politecnico", "stops": ["812", "813"]},
          "lines": [{"line": "4", "vehicle": "Tram", "towards": "Falchera", "arrivals": [
            {"at": "2026-10-22T06:07:00Z", "scheduled": "2026-10-22T06:05:00Z", "live": true, "delay": 120,
             "to_at": "2026-10-22T06:32:00Z", "to_stop": "813"},
            {"at": "2026-10-22T06:15:00Z", "scheduled": "2026-10-22T06:15:00Z", "live": false, "delay": null}]}]}]}]
        """
        let attachments = try JSONDecoder.api.decode([Attachment].self, from: Data(json.utf8))
        guard case .departures(let boards) = attachments[0] else { return XCTFail("expected departures") }
        let board = try XCTUnwrap(boards.first)
        XCTAssertEqual(board.stop.code, "253")
        XCTAssertEqual(board.walk, 170)
        XCTAssertEqual(board.to?.stops, ["812", "813"])
        let first = board.lines[0].arrivals[0]
        XCTAssertEqual(first.delay, 120)
        XCTAssertEqual(first.arrivesDate?.timeIntervalSince(first.date!), 25 * 60)
        XCTAssertNil(board.lines[0].arrivals[1].delay)
        XCTAssertNil(board.lines[0].arrivals[1].toAt)
    }

    func testRoutesAttachmentDecodes() throws {
        let json = """
        [{"type": "routes", "routes": [
          {"id": "a1", "mode": "drive", "from": "where you are", "to": "SME, Torino", "duration": 380, "usual": 300,
           "distance": 2200, "depart": "2026-10-27T12:54:00Z", "arrive": "2026-10-27T13:00:20Z", "rides": [],
           "url": "https://www.google.com/maps/dir/?api=1"},
          {"id": "b2", "mode": "transit", "from": "SME", "to": "Piazza Castello 32", "duration": 1080, "usual": null,
           "distance": 5100, "depart": "2026-10-27T12:11:00Z", "arrive": "2026-10-27T12:27:00Z",
           "rides": [{"line": "4", "vehicle": "Tram", "towards": "Drosso", "from": "Porta Nuova",
                      "depart": "2026-10-27T12:11:00Z", "to": "Castello", "arrive": "2026-10-27T12:27:00Z"},
                     {"line": null, "vehicle": "Bus", "towards": null, "from": null, "depart": null, "to": null,
                      "arrive": null}],
           "url": "https://www.google.com/maps/dir/?api=1"}]}]
        """
        let attachments = try JSONDecoder.api.decode([Attachment].self, from: Data(json.utf8))
        guard case .routes(let routes) = attachments[0] else { return XCTFail("expected routes") }
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].usual, 300)
        XCTAssertEqual(routes[0].arriveDate?.timeIntervalSince(routes[0].departDate!), 380)
        XCTAssertEqual(routes[1].rides[0].line, "4")
        XCTAssertNil(routes[1].rides[1].departDate)
        XCTAssertEqual(RouteCard.duration(380), "6 min")
        XCTAssertEqual(RouteCard.duration(3900), "1 h 5 min")
        XCTAssertEqual(RouteCard.distance(2200), "2.2 km")
    }

    func testFilesAndProposalAttachmentsDecode() throws {
        let json = """
        [{"type": "files", "files": [{"id": "f_1", "course": 2, "lecture": null, "name": "Lect: Monetary Policy.pdf",
          "section": "Week 6", "size": 100, "pages": 24, "scanned": false, "source": "moodle",
          "added_at": "2026-10-26T17:00:00+01:00"}]},
         {"type": "proposal", "proposal": {"id": "p_1", "course": 2, "kind": "update", "status": "pending",
          "items": [{"n": 1, "topic": "t_1", "title": "Money", "add": "The credit channel.", "sources": ["Lect, p. 3"]},
                    {"n": 2, "topic": null, "title": "Monetary policy rule", "add": "", "sources": []}],
          "material": ["Lect: Monetary Policy"], "result": null, "progress": null, "conversation_id": "c_9",
          "created_at": "2026-10-26T17:00:00+01:00"}}]
        """
        let attachments = try JSONDecoder.api.decode([Attachment].self, from: Data(json.utf8))
        guard case .files(let files) = attachments[0], case .proposal(let p) = attachments[1] else {
            return XCTFail("expected files and a proposal")
        }
        XCTAssertEqual(StudyFileRow.title(files[0]), "Lect: Monetary Policy")
        XCTAssertEqual(StudyFileRow.detail(files[0]), "24 pages · Week 6 · from Moodle")
        XCTAssertEqual(p.items?.map(\.title), ["Money", "Monetary policy rule"])
        XCTAssertEqual(p.conversationId, "c_9")
        XCTAssertNil(p.items?[1].topic)
    }

    func testTransitAlertPatchSendsOnlyWhatChanges() throws {
        func json(_ patch: TransitAlertPatch) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(patch)) as? [String: Any])
        }
        let off = try json(TransitAlertPatch(enabled: false))
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off["enabled"] as? Bool, false)
        let leave = try json(TransitAlertPatch(minutes: .some(nil)))
        XCTAssertTrue(leave["minutes"] is NSNull) // back to when it's time to leave
        XCTAssertEqual(try json(TransitAlertPatch(time: "08:20", minutes: 8))["minutes"] as? Int, 8)
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

    func testNapsAreTheDaysOtherSleepNotTheNextNight() {
        let segments = [
            seg(.core, (2, 16), (7, 53)), // the night
            seg(.core, (10, 30), (12, 0)),
            seg(.rem, (12, 0), (12, 40)), // one nap, 2h10
            seg(.core, (16, 0), (16, 5)), // 5 min: dozing, not a nap
            seg(.core, (20, 30), (23, 59)), // the next night, early
        ]
        let naps = SleepSummary.naps(on: at(12), from: segments, calendar: calendar)
        XCTAssertEqual(naps.count, 1)
        XCTAssertEqual(naps.first.flatMap { Wire.parse($0.start) }, at(10, 30))
        XCTAssertEqual(naps.first.flatMap { Wire.parse($0.end) }, at(12, 40))
        XCTAssertEqual(naps.first?.asleepMin, 130)
    }

    func testANapWithoutStagesCountsNextToAWatchNight() {
        let segments = [
            seg(.asleep, (2, 0), (7, 50)), // the iPhone's copy of the night
            seg(.core, (2, 16), (7, 53)), // the Watch's night
            seg(.asleep, (10, 15), (12, 30)), // a nap with no stages
        ]
        let night = SleepSummary.night(endingOn: at(12), from: segments, calendar: calendar)
        XCTAssertEqual(night?.asleepMin, 337)
        XCTAssertEqual(SleepSummary.naps(on: at(12), from: segments, calendar: calendar).map(\.asleepMin), [135])
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

    func testObjectivesDecodeInBlocksAndInTheDigest() throws {
        let objective = #"""
        {"id":"o_3f9a1c2b7d4e","agent":"coach","period":"week","start":"2026-10-19","end":"2026-10-25",
         "title":"Run 3 times","why":"Half marathon","measure":{"type":"habit","habit":4,"label":"check-ins of Run"},
         "progress":1,"target":3,"done":false,"status":"proposed","parent":null,"added_by":"agent"}
        """#
        let block = #"{"period":"week","start":"2026-10-19","end":"2026-10-25","planned":true,"objectives":[\#(objective)]}"#
        let empty = #"{"period":"day","start":"2026-10-22","end":"2026-10-22","planned":false,"objectives":[]}"#
        let overview = try JSONDecoder.api.decode(ObjectivesOverview.self,
                                                  from: Data(#"{"day":\#(empty),"week":\#(block),"month":\#(empty)}"#.utf8))
        let o = try XCTUnwrap(overview["week"].objectives.first)
        XCTAssertEqual(o.measure?.label, "check-ins of Run")
        XCTAssertTrue(o.isProposed && !o.isManual)
        XCTAssertEqual(overview["week"].proposed.count, 1)
        XCTAssertFalse(overview["day"].planned)

        let digest = #"{"kind":"daily","greeting":"Morning.","sections":[{"type":"objectives","title":"Objectives for today","period":"week","start":"2026-10-19","objectives":[\#(objective)]}]}"#
        let d = try JSONDecoder.api.decode(Digest.self, from: Data(digest.utf8))
        guard case .objectives(let list, let period) = d.sections[0].content else { return XCTFail() }
        XCTAssertEqual(list.first?.addedBy, "agent")
        XCTAssertEqual(period, "week")
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

    func testLimitHabit() throws {
        let json = #"""
        {"id":4,"name":"Coffee","cadence":{"type":"limit","max":5},"streak":2,"done_today":true,"last_done":"2026-10-25",
         "history":["2026-10-24","2026-10-25"],"workouts":[],"food":null,"count":2,"counts":{"2026-10-26":2}}
        """#
        let habit = try JSONDecoder.api.decode(Habit.self, from: Data(json.utf8))
        XCTAssertTrue(habit.isLimit)
        XCTAssertEqual(habit.cadence.max, 5)
        XCTAssertEqual(habit.count, 2)
        XCTAssertEqual(HabitRow.detail(habit), "At most 5 a day · 2 today")
    }

    func testNewHabitSendsFoodEvenWhenOff() throws {
        let new = HabitNew(name: "Eat well", cadence: .init(type: "daily", perWeek: nil), workouts: [], food: nil)
        let json = String(decoding: try JSONEncoder.api.encode(new), as: UTF8.self)
        XCTAssertTrue(json.contains(#""food":null"#), json)
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

    func testDrinksDecodeAndAnOlderServerWithoutThemIsZero() throws {
        XCTAssertEqual(try JSONDecoder.api.decode(Meal.self, from: Data(meal.utf8)).waterMl, 0)
        let json = #"""
        {"meals":[{"id":3,"name":"Espresso and 1 L water","eaten_at":"2026-10-27T10:00:00+01:00","calories":10,
          "protein_g":0,"carbs_g":1,"fat_g":0,"water_ml":1030,"caffeine_mg":65,"photo":null,"notes":""}]}
        """#
        let m = try XCTUnwrap(JSONDecoder.api.decode(MealList.self, from: Data(json.utf8)).meals.first)
        XCTAssertEqual(m.waterMl, 1030)
        XCTAssertEqual(m.caffeineMg, 65)
        var changed = m
        changed.waterMl = 530
        XCTAssertNotEqual(HealthService.version(m, []), HealthService.version(changed, [])) // written again
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

    func testChatSaysWhenItWasSpoken() throws {
        let spoken = try JSONEncoder.api.encode(ChatRequest(text: "quiz me", voice: true))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: spoken) as? [String: Any])?["voice"] as? Bool, true)
        let typed = try JSONEncoder.api.encode(ChatRequest(text: "quiz me"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: typed) as? [String: Any])?["voice"])
    }

    func testReviewSessionsAndChatQuizzesDecode() throws {
        let json = #"""
        {"sessions": [{"id": "v_1a2b3c4d5e6f", "course": 2, "start": "2026-10-28T15:00:00+01:00", "minutes": 90,
                       "topics": ["The IS-LM model", "Phillips curve"]}]}
        """#
        let list = try JSONDecoder.api.decode(ReviewSessionList.self, from: Data(json.utf8))
        XCTAssertEqual(list.sessions.first?.minutes, 90)
        XCTAssertEqual(list.sessions.first?.topics, ["The IS-LM model", "Phillips curve"])
        let quiz = #"""
        {"id": "x_1", "kind": "chat", "course": 2, "minutes": null, "count": 1, "started_at": "2026-10-27T10:00:00+01:00",
         "finished_at": null, "score": null,
         "questions": [{"n": 1, "topic": {"id": "t_1", "title": "IS-LM"}, "text": "What shifts LM?", "options": [],
                        "type": "card"}]}
        """#
        let q = try JSONDecoder.api.decode(Quiz.self, from: Data(quiz.utf8))
        XCTAssertEqual(q.kind, "chat")
        XCTAssertEqual(q.questions.first?.options, [])
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

@MainActor
final class ScannedFoodTests: XCTestCase {
    private let nocciolata = #"""
    {"id":7,"name":"Nocciolata","brand":"Rigoni di Asiago","barcode":"8001505005707","kcal_100g":544.0,
     "protein_100g":8.1,"carbs_100g":54,"fat_100g":32,"serving_g":15.0,"usual_g":null,"source":"off"}
    """#

    private func makeClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return APIClient(session: URLSession(configuration: cfg),
                         config: { APIConfig(baseURL: URL(string: "https://aide.test")!, token: "secret") })
    }

    private func json(_ req: URLRequest) -> [String: Any]? {
        req.httpBodyStream.flatMap { stream in
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(buffer, count: n) }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// An EAN-13 drawn by hand: its bars as 0s and 1s, `module` points each, with a quiet zone, on white.
    private func ean13(_ code: String, module: CGFloat = 3) -> UIImage {
        let l = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
        let r = l.map { String($0.map { $0 == "0" ? "1" : "0" }) }
        let g = r.map { String($0.reversed()) }
        let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
        let d = code.compactMap(\.wholeNumberValue)
        var bars = "101"
        for (i, p) in parity[d[0]].enumerated() { bars += (p == "L" ? l : g)[d[i + 1]] }
        bars += "01010"
        for digit in d[7...] { bars += r[digit] }
        bars += "101"
        let size = CGSize(width: CGFloat(bars.count + 20) * module, height: 60 * module)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for (i, bar) in bars.enumerated() where bar == "1" {
                ctx.fill(CGRect(x: CGFloat(i + 10) * module, y: 5 * module, width: module, height: 50 * module))
            }
        }
    }

    func testABarcodeIsReadInAPhotoOnThePhone() throws {
        let photo = ean13("8001505005707")
        XCTAssertEqual(BarcodeReader.codes(in: photo), ["8001505005707"])
        XCTAssertEqual(BarcodeReader.codes(in: try XCTUnwrap(photo.jpegData(compressionQuality: 0.75))), ["8001505005707"])
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { _ in }
        XCTAssertEqual(BarcodeReader.codes(in: blank), [])
        // Read barcodes go along to Coach when the photo isn't a lone packet.
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(
            FoodLogRequest(photos: ["p_1"], barcodes: ["8001505005707"]))) as? [String: Any]
        XCTAssertEqual(body?["barcodes"] as? [String], ["8001505005707"])
    }

    func testSavedFoodDecodesAndWorksOutAPortion() throws {
        let food = try JSONDecoder.api.decode(SavedFood.self, from: Data(nocciolata.utf8))
        XCTAssertEqual(food.kcal100g, 544)
        XCTAssertEqual(food.servingG, 15)
        XCTAssertNil(food.usualG)
        XCTAssertEqual(food.defaultGrams, 15) // no usual portion yet: one serving
        let p = food.portion(15)
        XCTAssertEqual([p.calories, p.protein, p.carbs, p.fat], [80, 1, 8, 5])
        XCTAssertEqual(ScanSheet.g(15), "15 g")
        XCTAssertEqual(ScanSheet.g(12.5), "\(12.5.formatted(.number.precision(.fractionLength(1)))) g") // 12,5 in Italian
    }

    func testABarcodeIsLookedUpAndLoggedWithOptionalGrams() async throws {
        let api = makeClient()
        var seen: [(URLRequest, [String: Any]?)] = []
        StubURLProtocol.handler = { req in
            seen.append((req, self.json(req)))
            switch req.url?.path {
            case "/v1/food/barcode/8001505005707": return (200, "{\"food\":\(self.nocciolata)}")
            case "/v1/food/barcode/123456": return (200, #"{"food":null}"#)
            default: return (200, #"{"meal":{"id":3,"name":"Nocciolata (Rigoni di Asiago)","eaten_at":"2026-10-29T08:00:00+01:00","calories":80,"protein_g":1,"carbs_g":8,"fat_g":5,"notes":"Items: Nocciolata 15 g"}}"#)
            }
        }
        let food = try await api.food(barcode: "8001505005707")
        XCTAssertEqual(food?.name, "Nocciolata")
        let none = try await api.food(barcode: "123456")
        XCTAssertNil(none)
        let meal = try await api.logFood(7, FoodPortion(grams: nil, date: nil))
        XCTAssertEqual(meal.calories, 80)
        XCTAssertEqual(seen.last?.0.url?.path, "/v1/food/foods/7/log")
        XCTAssertEqual(seen.last?.1?.isEmpty, true) // no grams: the server's usual or one serving
        _ = try await api.logFood(7, FoodPortion(grams: 30, date: "2026-10-28"))
        XCTAssertEqual(seen.last?.1?["grams"] as? Double, 30)
        XCTAssertEqual(seen.last?.1?["date"] as? String, "2026-10-28")
        _ = try await api.logFood(7, FoodPortion(grams: 30, conversationId: "c_coach")) // scanned in Coach's chat
        XCTAssertEqual(seen.last?.1?["conversation_id"] as? String, "c_coach")
    }
}

final class ScreenTimeTests: XCTestCase {
    /// A local wall-clock time on 2026-10-27, a Tuesday, plus `days`.
    private func local(_ hhmm: String, days: Int = 0) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27 + days, hour: parts[0], minute: parts[1]))!
        return base
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    private func lock(once: Bool = false, start: String? = "23:00", end: String? = "07:00", days: [Int]? = [],
                      startsAt: Date? = nil, endsAt: Date? = nil, enabled: Bool = true, openUntil: Date? = nil) throws -> ScreenLock {
        var json: [String: Any] = ["id": 1, "title": "Bedtime", "once": once, "enabled": enabled, "locked": false,
                                   "summary": "Every day 23:00–07:00"]
        if let start { json["start"] = start }
        if let end { json["end"] = end }
        if let days { json["days"] = days }
        if let startsAt { json["starts_at"] = iso(startsAt) }
        if let endsAt { json["ends_at"] = iso(endsAt) }
        if let openUntil { json["open_until"] = iso(openUntil) }
        return try JSONDecoder.api.decode(ScreenLock.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testOvernightScheduleHoldsOnItsDays() throws {
        // Sunday to Thursday nights: Tuesday's runs into Wednesday morning; Friday night has none.
        let bedtime = try lock(days: [7, 1, 2, 3, 4])
        XCTAssertNil(LockBook.until(bedtime, at: local("22:59")))
        XCTAssertEqual(LockBook.until(bedtime, at: local("23:30")), local("07:00", days: 1))
        XCTAssertEqual(LockBook.until(bedtime, at: local("06:59", days: 1)), local("07:00", days: 1))
        XCTAssertNil(LockBook.until(bedtime, at: local("07:00", days: 1)))
        XCTAssertNil(LockBook.until(bedtime, at: local("23:30", days: 3))) // Friday
        XCTAssertNil(LockBook.until(try lock(days: [], enabled: false), at: local("23:30")))
    }

    func testEndedEarlyStaysOpenUntilItsEnd() throws {
        let opened = try lock(openUntil: local("07:00", days: 1))
        XCTAssertNil(LockBook.until(opened, at: local("23:30")))
        XCTAssertNotNil(LockBook.until(opened, at: local("23:30", days: 1))) // the next night it's back
    }

    func testStrictAndPassesDecode() throws {
        XCTAssertFalse(try lock().isStrict) // an older server sends no strict
        let json = #"""
        {"locks":[{"id":4,"title":"Exam prep","once":true,"starts_at":"2026-10-27T15:00:00+01:00",
          "ends_at":"2026-10-27T17:00:00+01:00","enabled":true,"strict":true,"locked":true,"summary":"From 15:00 to 17:00"}],
         "device":{"authorized":true,"allowed_apps":2,"at":null},
         "passes":{"left":2,"month":3,"renews":"2026-11-01","used":[{"title":"Bedtime","reason":"a call","at":"2026-10-20T23:40:00+02:00"}]}}
        """#
        let list = try JSONDecoder.api.decode(LockList.self, from: Data(json.utf8))
        XCTAssertTrue(list.locks[0].isStrict)
        XCTAssertEqual(list.passes?.left, 2)
        XCTAssertEqual(list.passes?.used.first?.reason, "a call")
    }

    func testOneOffAndItsSchedule() throws {
        let focus = try lock(once: true, start: nil, end: nil, days: nil, startsAt: local("15:00"), endsAt: local("16:00"))
        XCTAssertEqual(LockBook.until(focus, at: local("15:30")), local("16:00"))
        XCTAssertNil(LockBook.until(focus, at: local("16:00")))
        let schedule = try XCTUnwrap(LockBook.schedule(for: focus, now: local("15:30")))
        XCTAssertFalse(schedule.repeats)
        XCTAssertEqual(schedule.intervalStart.minute, 30) // from now, not from its start
        XCTAssertNil(LockBook.schedule(for: focus, now: local("16:01")))
        let weekly = try XCTUnwrap(LockBook.schedule(for: try lock()))
        XCTAssertTrue(weekly.repeats)
        XCTAssertEqual(weekly.intervalStart.hour, 23)
        XCTAssertEqual(weekly.intervalEnd.hour, 7)
    }
}

final class ErrandTests: XCTestCase {
    static let errand = #"""
    {"id": 7, "title": "USB-C cable", "task": "A cheap 2 m USB-C cable", "site": "amazon.it",
     "url": "https://www.amazon.it/ap/signin", "status": "needs_you", "why": "login", "reason": "Log in to Amazon.",
     "options": null, "step": "Log in to Amazon.", "steps": [{"ts": "2026-10-27T18:02:11+01:00", "text": "Opened amazon.it"}],
     "result": null, "action_id": null, "conversation_id": "c_91f", "purchase_id": null,
     "created_at": "2026-10-27T18:01:50+01:00", "updated_at": "2026-10-27T18:03:20+01:00"}
    """#

    func testErrandDecodesAndSaysWhatItNeeds() throws {
        let e = try JSONDecoder.api.decode(Errand.self, from: Data(Self.errand.utf8))
        XCTAssertTrue(e.needsLiveView)
        XCTAssertFalse(e.needsAnswer)
        XCTAssertEqual(e.line, "Log in to Amazon.")
        XCTAssertEqual(e.conversationId, "c_91f")
        XCTAssertEqual(e.steps.first?.text, "Opened amazon.it")
        let question = try JSONDecoder.api.decode(Errand.self, from: Data(Self.errand
            .replacingOccurrences(of: #""why": "login""#, with: #""why": "question""#)
            .replacingOccurrences(of: #""options": null"#, with: #""options": ["2 m", "1 m"]"#).utf8))
        XCTAssertTrue(question.needsAnswer)
        XCTAssertFalse(question.needsLiveView)
        XCTAssertEqual(question.options, ["2 m", "1 m"])
    }

    func testApprovalsCarryErrandsAndTheOrder() throws {
        let json = """
        {"waiting": 2,
         "actions": [{"id": 42, "summary": "Order the Anker USB-C cable", "agent": "aide", "conversation_id": "c_91f",
                      "created_at": "2026-10-27T18:03:00+01:00", "expires_at": "2026-10-27T18:33:00+01:00",
                      "detail": {"kind": "purchase", "errand_id": 7, "site": "amazon.it", "summary": "Order the Anker USB-C cable",
                                 "items": [{"title": "Anker USB-C cable 2 m", "quantity": "2", "price": "9,99 €", "image": null}],
                                 "total": "12,98 €", "delivery": null, "address": "Via Roma 1, Torino",
                                 "screenshot": "p_3f2a", "button": "Acquista ora"}},
                     {"id": 43, "summary": "Delete reminder 'Bins'", "agent": "secretary", "detail": null}],
         "objectives": [], "proposals": [], "writer": null, "upcoming": [],
         "errands": [\(Self.errand)]}
        """
        let a = try JSONDecoder.api.decode(Approvals.self, from: Data(json.utf8))
        let order = try XCTUnwrap(a.actions[0].purchase)
        XCTAssertEqual(order.total, "12,98 €")
        XCTAssertEqual(order.items?.first?.quantity, 2)
        XCTAssertEqual(order.button, "Acquista ora")
        XCTAssertNil(a.actions[1].purchase)
        XCTAssertEqual(a.errands?.first?.id, 7)
    }

    func testErrandAndPurchaseAttachmentsDecode() throws {
        let json = """
        [{"type": "errands", "errands": [\(Self.errand)]},
         {"type": "purchases", "purchases": [{"id": 3, "errand_id": 7, "site": "amazon.it", "title": "Anker USB-C cable",
           "items": [{"title": "Anker USB-C cable 2 m", "quantity": 1, "price": "9,99 €", "image": null}],
           "total": "12,98 €", "amount": 12.98, "currency": "EUR", "order_ref": "402-1234567-7654321",
           "delivery": "Tomorrow, 28 Oct", "receipt": "p_9c1e", "placed_at": "2026-10-27T18:04:02+01:00"}]}]
        """
        let attachments = try JSONDecoder.api.decode([Attachment].self, from: Data(json.utf8))
        guard case .errands(let errands) = attachments[0], case .purchases(let purchases) = attachments[1] else {
            return XCTFail("expected an errand and a purchase")
        }
        XCTAssertEqual(errands.first?.siteName, "amazon.it")
        XCTAssertEqual(purchases.first?.orderRef, "402-1234567-7654321")
        XCTAssertNotNil(purchases.first?.date)
    }

    func testProductsAttachmentDecodes() throws {
        let json = """
        [{"type": "products", "errand_id": 3, "site": "amazon.it", "products": [
          {"title": "Lodge L8SK3, 26 cm", "url": "https://www.amazon.it/dp/B00006JSUA", "price": "49,15 €",
           "rating": 4.4, "reviews": 72015, "note": null, "image": "https://m.media-amazon.com/images/I/81q.jpg"},
          {"title": "Victoria, 30 cm", "url": "https://www.amazon.it/dp/B01726HD72", "price": null,
           "rating": null, "reviews": null, "note": "6 left", "image": null}]}]
        """
        let attachments = try JSONDecoder.api.decode([Attachment].self, from: Data(json.utf8))
        guard case .products(let products) = attachments[0] else { return XCTFail("expected products") }
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(products[0].link?.host, "www.amazon.it")
        XCTAssertNotNil(products[0].stars)
        XCTAssertNil(products[1].stars)
        XCTAssertEqual(products[1].note, "6 left")
        // An errand from before products has none.
        XCTAssertNil(try JSONDecoder.api.decode(Errand.self, from: Data(Self.errand.utf8)).products)
    }

    func testLiveActionLines() throws {
        let tap = try JSONDecoder.api.decode(BrowserLive.Action.self, from: Data("""
        {"type": "action", "seq": 3, "kind": "click", "x": 0.5, "y": 0.38, "label": "Aggiungi al carrello"}
        """.utf8))
        XCTAssertEqual(tap.line, "Tapping “Aggiungi al carrello”")
        XCTAssertEqual(tap.point, CGPoint(x: 0.5, y: 0.38))
        let secret = try JSONDecoder.api.decode(BrowserLive.Action.self, from: Data("""
        {"seq": 4, "kind": "type", "x": null, "y": null, "label": null}
        """.utf8))
        XCTAssertEqual(secret.line, "Typing")
        XCTAssertNil(secret.point)
    }

    func testScenesDecode() throws {
        let results = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"type": "scene", "kind": "results", "site": "amazon.it", "title": "Amazon.it : padella", "url": "https://www.amazon.it/s?k=padella",
         "icon": "https://www.amazon.it/favicon.ico", "query": "padella in ghisa",
         "items": [{"title": "VICTORIA Padella in Ghisa 30 cm", "price": "49,52 €", "image": "https://m.media-amazon.com/a.jpg", "ref": "41"},
                   {"title": "KICHLY Padella in ghisa 12 pollici", "price": null, "image": null, "ref": "42"}],
         "product": null, "cart": {"count": 2, "total": null}, "form": null, "captcha": null, "signin": "3"}
        """.utf8))
        XCTAssertEqual(results.items.map(\.ref), ["41", "42"])
        XCTAssertEqual(results.cart?.count, 2)
        XCTAssertFalse(results.isYourTurn)
        XCTAssertEqual(results.signin, "3")
        // The result Aide tapped, from what the tap was on.
        let tap = BrowserLive.Action(seq: 1, kind: "click", label: "KICHLY Padella in ghisa 12 pollici, pre-stagionata")
        XCTAssertEqual(results.item(clicked: tap)?.ref, "42")
        XCTAssertNil(results.item(clicked: BrowserLive.Action(seq: 2, kind: "scroll", label: "down")))
        // A menu's "+": the label names its dish.
        let menu = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"kind": "results", "items": [{"title": "farinata", "price": "4,40 €", "ref": "20"},
                                      {"title": "diavola", "price": "8,00 €", "ref": "22"}]}
        """.utf8))
        let plus = BrowserLive.Action(seq: 3, kind: "click", label: "Increase quantity · diavola")
        XCTAssertEqual(menu.item(clicked: plus)?.ref, "22")
        XCTAssertTrue(plus.addsToCart)

        let login = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"kind": "login", "site": "amazon.it", "title": "Accedi", "url": "https://www.amazon.it/ap/signin", "icon": null, "query": null,
         "items": [], "product": null, "cart": null, "captcha": null,
         "form": {"fields": [{"ref": "7", "kind": "username", "label": "E-mail", "filled": false},
                             {"ref": "9", "kind": "password", "label": null, "filled": true}],
                  "submit": {"ref": "8", "text": "Continua"}, "choices": [], "remember": "10", "remembered": false,
                  "error": "Password errata"}}
        """.utf8))
        XCTAssertTrue(login.isYourTurn)
        XCTAssertEqual(login.turnTitle, "Log in to amazon.it")
        XCTAssertEqual(login.form?.submit?.text, "Continua")
        let form = try XCTUnwrap(login.form)
        XCTAssertFalse(StageSheet.ready(form, [:]))  // the email is missing; the password was there
        XCTAssertTrue(StageSheet.ready(form, ["7": "me@example.it"]))

        let captcha = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"kind": "captcha", "site": "amazon.it", "title": "Amazon.it", "url": null, "icon": null, "query": null, "items": [],
         "product": null, "cart": null, "form": null,
         "captcha": {"kind": "text", "ref": "12", "input_ref": "13", "submit_ref": null}}
        """.utf8))
        XCTAssertEqual(captcha.captcha?.inputRef, "13")
        XCTAssertEqual(captcha.turnButton, "Solve it")

        let product = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"kind": "product", "site": "amazon.it", "title": "Lodge", "url": "https://www.amazon.it/dp/B0", "icon": null, "query": null,
         "items": [], "product": {"title": "Lodge L8SK3", "price": "49,15 €", "image": null, "rating": 4.4},
         "cart": null, "form": null, "captcha": null}
        """.utf8))
        XCTAssertEqual(product.product?.rating, 4.4)
    }

    func testTimetableScene() throws {
        let scene = try JSONDecoder.api.decode(PageScene.self, from: Data("""
        {"kind": "rows", "site": "lefrecce.it", "items": [], "rows": [
          {"times": ["05:20", "06:14"], "title": "Regionale Veloce 2713", "places": ["Torino Porta Nuova", "Ivrea"],
           "detail": "54min", "price": "7,10€", "ref": "2"},
          {"times": ["05:54", "07:39"], "title": "Regionale Veloce 2013", "places": ["Torino Porta Nuova", "Ivrea"],
           "detail": "1h 45min · 1 cambio", "price": null, "ref": "3"}]}
        """.utf8))
        XCTAssertEqual(scene.rows?.map(\.leaves), ["05:20", "05:54"])
        XCTAssertEqual(scene.rows?.first?.symbol, "train.side.front.car")
        let tap = BrowserLive.Action(seq: 1, kind: "click", label: "2013 1 da 7,10€ 05:54 1h 45min 07:39 Torino Porta Nuova Ivrea")
        XCTAssertEqual(scene.tapped(tap), "3")
        // A server from before rows: none.
        let old = try JSONDecoder.api.decode(PageScene.self, from: Data(#"{"kind": "page", "items": []}"#.utf8))
        XCTAssertNil(old.rows)
    }

    func testNarrationAndTheCaptchaTaps() throws {
        let said = try JSONDecoder.api.decode(BrowserLive.Action.self, from: Data("""
        {"seq": 5, "kind": "read", "x": null, "y": null, "label": null, "note": "Guardo le recensioni"}
        """.utf8))
        XCTAssertEqual(ErrandLiveBox.narration(action: said, step: "Clicked [3]"), "Guardo le recensioni")
        let plain = BrowserLive.Action(seq: 6, kind: "click", label: "Aggiungi al carrello")
        XCTAssertEqual(ErrandLiveBox.narration(action: plain, step: nil), "Tapping “Aggiungi al carrello”")
        XCTAssertTrue(plain.addsToCart)
        XCTAssertEqual(ErrandLiveBox.narration(action: nil, step: "Cerco padelle"), "Cerco padelle")
        XCTAssertEqual(ErrandLiveBox.narration(action: nil, step: nil), "Opening the page…")

        // A tap on the CAPTCHA's picture lands where the picture is on the page.
        let crop = BrowserLive.Crop(image: UIImage(), box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.2))
        let point = crop.pagePoint(u: 0.5, v: 0.5)
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.4, accuracy: 1e-9)

        var e = try JSONDecoder.api.decode(Errand.self, from: Data(Self.errand.utf8))
        XCTAssertEqual(ErrandButtons.yourPart(e), "Log in")
        e.why = "captcha"
        XCTAssertEqual(ErrandButtons.yourPart(e), "Solve it")
        e.why = "card"
        XCTAssertEqual(ErrandButtons.yourPart(e), "Take over")
    }

    func testErrandRoutes() throws {
        XCTAssertEqual(PushRoute(url: try XCTUnwrap(URL(string: "aide://errand/7"))), .errand(7))
        XCTAssertNil(PushRoute(url: try XCTUnwrap(URL(string: "aide://errand/x"))))
        XCTAssertEqual(PushRoute(userInfo: ["aide": ["kind": "errand", "errand_id": 7, "conversation_id": "c_91f"]]), .errand(7))
        XCTAssertNil(PushRoute(userInfo: ["aide": ["kind": "errand"]]))
        let activity = AgentActivityAttributes(key: "errand:7", agent: "aide", name: "Aide", color: "#34413F",
                                               conversation: "c_91f", title: "USB-C cable")
        XCTAssertEqual(activity.url?.absoluteString, "aide://errand/7")
        let state = AgentActivityAttributes.ContentState(status: "browsing", detail: "", text: "", since: 0, errand: 7)
        XCTAssertEqual(state.line(name: "Aide"), "Aide is browsing")
    }
}

/// The chat's events card (#25): its order, what it leaves out, and the week it opens on.
final class EventWeekTests: XCTestCase {
    private let rome: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        c.firstWeekday = 2
        return c
    }()

    private func events(_ json: String) throws -> [CalendarEvent] {
        try JSONDecoder.api.decode([CalendarEvent].self, from: Data(json.utf8))
    }

    private func at(_ s: String) -> Date { Wire.parse(s)! }

    func testPastEventsAreLeftOutAndTheStripOpensOnTheFirstNewOne() throws {
        let card = try events("""
        [{"id": "a", "title": "Lecture", "start": "2026-10-27T10:00:00+01:00", "end": "2026-10-27T12:00:00+01:00"},
         {"id": "b", "title": "Macro midterm", "start": "2026-11-04T08:00:00+01:00", "end": "2026-11-04T11:00:00+01:00",
          "change": "found"},
         {"id": "ep_1-1", "title": "Review: Macroeconomics", "start": "2026-11-03T15:00:00+01:00",
          "end": "2026-11-03T17:00:00+01:00", "change": "proposed", "plan": "ep_1", "status": "proposed"},
         {"id": "c", "title": "Gym", "start": "2026-10-30T18:00:00+01:00", "end": "2026-10-30T19:00:00+01:00"}]
        """)
        let now = at("2026-10-29T12:00:00+01:00")
        XCTAssertEqual(EventWeek.shown(card, now: now).map(\.id), ["c", "ep_1-1", "b"])
        let days = EventWeek.span(EventWeek.shown(card, now: now), now: now, calendar: rome)
        XCTAssertEqual(days.map { rome.component(.day, from: $0) }, [29, 30, 31, 1, 2, 3, 4])  // today to the last
        let day = EventWeek.selection(in: days, events: EventWeek.shown(card, now: now), now: now, calendar: rome)
        XCTAssertEqual(rome.component(.day, from: day), 3)  // the proposed session's day, not today
        XCTAssertTrue(card[2].isProposed && card[2].isNew && card[2].calendarID == nil)
        XCTAssertEqual(card[1].calendarID, "b")
    }

    func testAnAllDayTripIsOnEachOfItsDaysBeforeTimedEvents() throws {
        let card = try events("""
        [{"id": "t", "title": "Trip", "start": "2026-11-05", "end": "2026-11-08", "all_day": true},
         {"id": "d", "title": "Dinner", "start": "2026-11-06T20:00:00+01:00", "end": "2026-11-06T22:00:00+01:00"}]
        """)
        XCTAssertEqual(EventWeek.on(at("2026-11-06T12:00:00+01:00"), card, calendar: rome).map(\.id), ["t", "d"])
        XCTAssertEqual(EventWeek.on(at("2026-11-07T12:00:00+01:00"), card, calendar: rome).map(\.id), ["t"])
        XCTAssertEqual(EventWeek.on(at("2026-11-08T12:00:00+01:00"), card, calendar: rome).map(\.id), [])
    }

    func testEverythingPastStillShows() throws {
        let card = try events("""
        [{"id": "a", "title": "Lecture", "start": "2026-10-20T10:00:00+02:00", "end": "2026-10-20T12:00:00+02:00"}]
        """)
        XCTAssertEqual(EventWeek.shown(card, now: at("2026-10-29T12:00:00+01:00")).map(\.id), ["a"])
    }

    func testAStripIsAtLeastAWeekAndReachesAMovedEvent() throws {
        let now = at("2026-10-29T12:00:00+01:00")
        XCTAssertEqual(EventWeek.span([], now: now, calendar: rome).count, 7)
        let moved = at("2026-11-20T09:00:00+01:00")
        XCTAssertEqual(EventWeek.span([], through: moved, now: now, calendar: rome).last.map(Wire.dayString), "2026-11-20")
    }

    func testAnEventCarriesItsCalendarsColour() throws {
        let card = try events("""
        [{"id": "a", "title": "Run", "calendar": "Run", "color": "#00274A",
          "start": "2026-10-29T17:00:00+01:00", "end": "2026-10-29T18:00:00+01:00"}]
        """)
        XCTAssertEqual(card[0].color, "#00274A")
    }

    func testAnAddedItemMovesItsEvent() throws {
        let item = try events("""
        [{"id": "ep_1-1", "title": "Run", "start": "2026-11-03T15:00:00+01:00", "end": "2026-11-03T16:00:00+01:00",
          "change": "proposed", "plan": "ep_1", "status": "added", "event": "uid-9"}]
        """)[0]
        XCTAssertEqual(item.calendarID, "uid-9")
        XCTAssertFalse(item.isProposed)
        XCTAssertTrue(item.isNew)
    }
}

final class NutritionTests: XCTestCase {
    func testAFoodDayCarriesItsTargetsBonusAndScore() throws {
        let json = #"""
        {"date": "2026-10-29", "meals": [], "totals": {"calories": 900, "protein_g": 30, "carbs_g": 150, "fat_g": 20},
         "goals": {"calories": 3160, "protein_g": 140, "carbs_g": 431, "fat_g": 95},
         "base": {"calories": 2500, "protein_g": 140, "carbs_g": 300, "fat_g": 80},
         "left": {"calories": 2260, "protein_g": 110, "carbs_g": 281, "fat_g": 75},
         "bonus": {"kcal": 656, "planned": false, "workouts": [{"type": "run", "kcal": 656, "minutes": 54}]},
         "score": {"score": 82, "final": false, "numbers": 90, "quality": null, "graded": 0.4,
                   "grades": {"a": 300, "b": 0, "c": 60, "d": 0, "e": 0}}}
        """#
        let day = try JSONDecoder.api.decode(FoodDay.self, from: Data(json.utf8))
        XCTAssertEqual(day.goals.calories, 3160)
        XCTAssertEqual(day.base.calories, 2500)
        XCTAssertEqual(day.left.carbsG, 281)
        XCTAssertEqual(day.score?.score, 82)
        XCTAssertNil(day.score?.quality)
        XCTAssertEqual(day.score?.grades["a"], 300)
        XCTAssertEqual(DayScoreCard.bonusLine(day.bonus), "+656 kcal from your run")

        // An older server: the base is the goals, no score.
        let old = try JSONDecoder.api.decode(FoodDay.self, from: Data(#"{"date": "2026-10-29", "goals": {"calories": 2500}}"#.utf8))
        XCTAssertEqual(old.base.calories, 2500)
        XCTAssertNil(old.score)
        XCTAssertNil(DayScoreCard.bonusLine(old.bonus))
    }

    func testTheScoreCarriesItsQualityParts() throws {
        let score = try JSONDecoder.api.decode(DayScore.self, from: Data(#"""
        {"score": 71, "final": true, "numbers": 90, "quality": 51, "graded": 1, "grades": {"a": 1000, "c": 1500},
         "parts": {"nutrients": 66, "processing": 0, "grades": 70},
         "nutrients": {"fibre": {"g": 12, "target": 30, "score": 10}, "fruit_veg": {"g": 200, "target": 400, "score": 50},
                       "sat_fat": {"pct": 6.5, "limit": 10, "score": 100}, "sugars": {"pct": 14.4, "limit": 10, "score": 71},
                       "salt": null},
         "processing": {"upf_pct": 60, "score": 0}}
        """#.utf8))
        XCTAssertEqual(score.parts?.processing, 0)
        XCTAssertEqual(score.nutrients?.fruitVeg?.g, 200)
        XCTAssertNil(score.nutrients?.salt)
        let lines = QualityLine.nutrients(score)
        XCTAssertEqual(lines.map(\.value), ["12 / 30 g", "200 / 400 g", "6.5% of kcal · under 10%",
                                            "14.4% of kcal · under 10%", "Not enough data"])
        XCTAssertEqual(lines[0].fill, 0.4, accuracy: 0.001)
        XCTAssertEqual(QualityLine.processing(score).value, "60% of kcal · under 10%")
        XCTAssertEqual(score.hint, "60% of kcal ultra-processed")

        // Before the parts: decodes, no lines' data, no hint.
        let old = try JSONDecoder.api.decode(DayScore.self, from: Data(#"""
        {"score": 82, "final": false, "numbers": 90, "quality": 70, "graded": 0.85, "grades": {"a": 640}}
        """#.utf8))
        XCTAssertNil(old.parts)
        XCTAssertNil(old.hint)
        XCTAssertEqual(QualityLine.processing(old).value, "Not enough data")
    }

    func testMealsShowNewestFirstWithTheirEmoji() throws {
        let meals = try JSONDecoder.api.decode([Meal].self, from: Data(#"""
        [{"id": 1, "name": "Oats", "eaten_at": "2026-10-29T08:00:00+01:00", "emoji": "🥣"},
         {"id": 2, "name": "Pasta", "eaten_at": "2026-10-29T13:00:00+01:00"},
         {"id": 3, "name": "Yogurt", "eaten_at": "2026-10-29T13:00:00+01:00", "emoji": "🥛"}]
        """#.utf8))
        XCTAssertEqual(Meal.newestFirst(meals).map(\.id), [3, 2, 1])
        XCTAssertEqual(meals.map(\.emoji), ["🥣", "🍽️", "🥛"])  // an older server: a plate
        XCTAssertEqual(meals[0].items, [])
        XCTAssertNil(meals[0].quality)
    }

    func testGramsCanBeASum() {
        XCTAssertEqual(Arithmetic.evaluate("125"), 125)
        XCTAssertEqual(Arithmetic.evaluate("12,5"), 12.5)
        XCTAssertEqual(Arithmetic.evaluate("400÷4"), 100)
        XCTAssertEqual(Arithmetic.evaluate("2×30+15"), 75)
        XCTAssertEqual(Arithmetic.evaluate("2 * (30 + 15)"), 90)
        XCTAssertEqual(Arithmetic.evaluate("250−40"), 210)
        XCTAssertEqual(Arithmetic.evaluate("-5+10"), 5)
        XCTAssertEqual(Arithmetic.evaluate("1.5x40"), 60)
        XCTAssertNil(Arithmetic.evaluate(""))
        XCTAssertNil(Arithmetic.evaluate("400/"))
        XCTAssertNil(Arithmetic.evaluate("400/0"))
        XCTAssertNil(Arithmetic.evaluate("(2+3"))
        XCTAssertTrue(Arithmetic.isSum("400/3"))
        XCTAssertFalse(Arithmetic.isSum("12,5"))
    }

    func testTheWeightTrendDecodesAndReads() throws {
        let list = try JSONDecoder.api.decode(WeightList.self, from: Data(#"""
        {"readings": [{"date": "2026-10-20", "kg": 66.2, "source": "health"},
                      {"date": "2026-10-27", "kg": 66.0, "source": "aide", "id": 3}],
         "summary": {"latest": {"date": "2026-10-27", "kg": 66.0}, "days_since": 2, "average_kg": 66.04,
                     "change_kg": -0.3, "rate_kg_week": -0.1, "goal": "gain",
                     "pace_kg_week": {"low_kg": 0.04, "high_kg": 0.08}, "verdict": "below"},
         "logged": [{"id": 3, "at": "2026-10-27T06:40:00+00:00", "kg": 66.0}]}
        """#.utf8))
        XCTAssertEqual(list.readings.map(\.id), [nil, 3])
        XCTAssertEqual(list.logged.first?.kg, 66)
        let s = list.summary
        XCTAssertEqual(s.shown, 66.04)
        XCTAssertEqual(s.shownLabel, "7-day average")
        let point = { (text: String?) in text?.replacingOccurrences(of: ",", with: ".") } // the locale's decimal mark
        XCTAssertEqual(point(s.trendLine), "−0.10 kg a week · Below the pace to gain")
        XCTAssertEqual(point(s.paceText), "+0.04 kg to +0.08 kg a week")
        XCTAssertTrue(s.isOff)
        let averages = WeightChart.averages(list.readings)
        XCTAssertEqual(averages.map { ($0.average * 100).rounded() }, [6620, 6600]) // a week apart: each alone

        let none = WeightSummary(daysSince: 59, goal: "gain")
        XCTAssertNil(none.verdictText)
        XCTAssertEqual(none.trendLine, "Last weighed 59 days ago")
    }

    func testTheMealCameraKeepsOnlyFoodBarcodes() {
        XCTAssertEqual(MealCamera.foodCode("8001505005707", type: .ean13), "8001505005707")
        XCTAssertEqual(MealCamera.foodCode("80052760", type: .ean8), "80052760")
        XCTAssertEqual(MealCamera.foodCode("01234565", type: .upce), "01234565")
        XCTAssertEqual(MealCamera.foodCode("8001505005707", type: .code128), "8001505005707")
        XCTAssertNil(MealCamera.foodCode("ABC-12345678", type: .code128)) // a parcel label, not a packet
        XCTAssertNil(MealCamera.foodCode("123456789", type: .code128))
        XCTAssertNil(MealCamera.foodCode("8001505005707", type: .qr))
        XCTAssertNil(MealCamera.foodCode(nil, type: .ean13))
        XCTAssertEqual(MealCamera.limit, 4)
    }

    func testTheMealCameraOffersTheLensesThePhoneHas() {
        // A Pro Max: ultra wide, wide from 2, the 5× telephoto from 10.
        let triple = MealCamera.lenses(kinds: [.builtInTripleCamera, .builtInUltraWideCamera, .builtInWideAngleCamera,
                                               .builtInTelephotoCamera], switchOvers: [2, 10], maxZoom: 123)
        XCTAssertEqual(triple.base, 2)
        XCTAssertEqual(triple.lenses.map(\.label), ["0.5", "1", "2", "5"])
        XCTAssertEqual(triple.lenses.map(\.factor), [1, 2, 4, 10])
        // A 2× telephoto: no 2 of its own beside it.
        let dual = MealCamera.lenses(kinds: [.builtInDualCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                     switchOvers: [2], maxZoom: 16)
        XCTAssertEqual(dual.lenses.map(\.label), ["1", "2"])
        XCTAssertEqual(dual.lenses.map(\.factor), [1, 2])
        // The wide alone.
        let wide = MealCamera.lenses(kinds: [.builtInWideAngleCamera], switchOvers: [], maxZoom: 10)
        XCTAssertEqual(wide.base, 1)
        XCTAssertEqual(wide.lenses.map(\.label), ["1", "2"])
    }

    func testAMealsFoodsCarryTheirQuality() throws {
        let meal = try JSONDecoder.api.decode(Meal.self, from: Data(#"""
        {"id": 1, "name": "Insalata", "quality": 97,
         "items": [{"name": "Mela", "grams": 150, "kcal": 78, "grade": "a", "nova": 1, "quality": 100},
                   {"name": "Biscotti", "grams": null, "kcal": 200, "grade": null, "nova": 4, "quality": null}]}
        """#.utf8))
        XCTAssertEqual(meal.quality, 97)
        XCTAssertEqual(meal.items, [MealItem(name: "Mela", grams: 150, kcal: 78, grade: "a", nova: 1, quality: 100),
                                    MealItem(name: "Biscotti", kcal: 200, nova: 4)])
        let targets = try JSONDecoder.api.decode(FoodTargets.self, from: Data(#"""
        {"base": {}, "workouts": {"on": true, "share": 1, "carbs_pct": 80},
         "profile": {"goal": "perform", "note": "Half marathon in March"},
         "coach": {"model": "Claude Sonnet 5.5", "via": "plan"}}
        """#.utf8))
        XCTAssertEqual(targets.coach, CoachModel(model: "Claude Sonnet 5.5", via: "plan"))
        XCTAssertEqual(targets.profile.note, "Half marathon in March")
        XCTAssertTrue(TargetGoal.all.contains { $0.id == targets.profile.goal })
    }

    func testCoachsQuestionsAndTheWorkoutLine() throws {
        let p = try JSONDecoder.api.decode(TargetsProposal.self, from: Data(#"""
        {"base": {"calories": 2300}, "workouts": {"on": true, "share": 0.9, "carbs_pct": 80}, "why": "",
         "questions": ["Is 65 kg still right?"]}
        """#.utf8))
        XCTAssertEqual(p.asks, ["Is 65 kg still right?"])
        XCTAssertEqual(TargetsSummary.workoutLine(p.workouts),
                       "Workout days add 90% of what the Watch says you burned, mostly as carbs.")
        let old = try JSONDecoder.api.decode(TargetsProposal.self, from: Data(#"""
        {"base": {}, "workouts": {"on": true, "share": 1, "carbs_pct": 50}, "why": ""}
        """#.utf8))
        XCTAssertEqual(old.asks, [])
        XCTAssertEqual(TargetsSummary.workoutLine(old.workouts), "Workout days add what the Watch says you burned, as carbs and fat.")
        let body = try JSONEncoder.api.encode(TargetsAnswers(answers: [.init(question: "Q?", answer: "A")]))
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]] // keys in any order
        XCTAssertEqual(sent, ["answers": [["question": "Q?", "answer": "A"]]])
    }

    func testAPlannedRunSaysWhatItsFor() throws {
        let bonus = try JSONDecoder.api.decode(FoodBonus.self, from: Data(#"""
        {"kcal": 540, "planned": true, "workouts": [{"type": "run", "kcal": 540, "minutes": 45, "title": "Corsa al Valentino"}]}
        """#.utf8))
        XCTAssertEqual(DayScoreCard.bonusLine(bonus), "+540 kcal for Corsa al Valentino")
    }

    func testTargetsEncodeSnakeCaseWithClearedProfileFields() throws {
        var targets = FoodTargets()
        targets.base = FoodGoals(calories: 2500, proteinG: 140)
        targets.workouts.carbsPct = 75
        targets.profile.weightKg = 74.5
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(targets)) as? [String: Any])
        let workouts = try XCTUnwrap(obj["workouts"] as? [String: Any])
        let profile = try XCTUnwrap(obj["profile"] as? [String: Any])
        XCTAssertEqual(workouts["carbs_pct"] as? Int, 75)
        XCTAssertEqual(profile["weight_kg"] as? Double, 74.5)
        XCTAssertTrue(profile["age"] is NSNull) // sent as null, so the server clears it
        XCTAssertEqual(try XCTUnwrap(JSONDecoder.api.decode(FoodTargets.self, from: JSONEncoder.api.encode(targets))), targets)
    }

    func testAProposalDecodes() throws {
        let p = try JSONDecoder.api.decode(TargetsProposal.self, from: Data(#"""
        {"base": {"calories": 2520, "protein_g": 135, "carbs_g": 310, "fat_g": 78},
         "workouts": {"on": true, "share": 0.8, "carbs_pct": 75}, "why": "You run 4 times a week."}
        """#.utf8))
        XCTAssertEqual(p.base.calories, 2520)
        XCTAssertEqual(p.workouts.share, 0.8)
        XCTAssertEqual(p.workouts.carbsPct, 75)
    }

    func testAHealthDaySendsWeightVO2MaxAndAWorkoutsDistance() throws {
        var day = HealthDay(date: "2026-10-29")
        day.weightKg = 74.2
        day.vo2max = 51.3
        day.workouts = [HealthWorkout(id: "w", type: "run", start: "a", end: "b", minutes: 54, kcal: 656, km: 9.8)]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(day)) as? [String: Any])
        XCTAssertEqual(obj["weight_kg"] as? Double, 74.2)
        XCTAssertEqual(obj["vo2max"] as? Double, 51.3)
        XCTAssertEqual((obj["workouts"] as? [[String: Any]])?.first?["km"] as? Double, 9.8)
    }
}
