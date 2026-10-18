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
    func testCalendarReplyBecomesEventCards() {
        let blocks = RichText.parse("**Tomorrow**\n- 09:00–10:00 Dentist\n- All day: Trip\nNothing else.")
        guard blocks.count == 4,
              case .event(let s, let e, let t) = blocks[1],
              case .event(let s2, _, let t2) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual([s, e, t], ["09:00", "10:00", "Dentist"])
        XCTAssertEqual([s2, t2], ["All day", "Trip"])
    }
}
