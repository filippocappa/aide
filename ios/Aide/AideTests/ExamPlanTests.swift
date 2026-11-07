import XCTest
@testable import Aide

/// The exam plan's shape (docs/API.md, "Exam plan"): minutes with decimals, nulls, and the words the app shows.
final class ExamPlanTests: XCTestCase {
    private let json = """
    {"computed_at": "2026-11-07T08:00:00Z",
     "today": [{"course": 4, "name": "business law", "phase": "learn", "minutes": 45.6,
                "topic": {"id": "t_1", "title": "Contracts"}},
               {"course": 2, "name": "maths", "phase": "review", "minutes": 20, "topic": null}],
     "targets": [{"course": 4, "name": "business law", "what": "2nd mid-term", "kind": "mid-term",
                  "date": "2026-12-03", "time": "11:00", "from": "calendar", "date_id": "d_1", "key": "d_1",
                  "topics_chosen": null, "days_left": 26, "fallback": null, "need_min": 1194, "free_min": 6240,
                  "planned_min": 1194, "short_min": 0, "status": "fits",
                  "phases": [{"phase": "learn", "minutes": 491, "planned": 490.3175, "from": "2026-11-07", "to": "2026-11-17"}],
                  "days": [{"date": "2026-11-07", "minutes": 46, "phases": {"learn": 46}}],
                  "topics": [{"id": "t_1", "title": "Contracts", "words": 1251, "cards": 15, "questions": 5,
                              "exercises": 0, "known": 0, "items": 20, "lesson": null, "learn_min": 21, "practise_min": 30.5}],
                  "mocks": {"count": 2, "taken": 0, "minutes_each": 60},
                  "lectures_left": 0, "lectures_held": 9, "stretch": 1.0, "studied_week_min": 0,
                  "warnings": ["No past exams yet."], "history": [{"date": "2026-11-07", "need_min": 1194}],
                  "moved": null}],
     "undated": [{"course": 7, "name": "micro"}],
     "settings": {"term_cap_min": 120, "season_cap_min": 240},
     "season_from": "2026-11-07",
     "assumptions": {"read_wpm": 120}}
    """

    func testDecodes() throws {
        let plan = try JSONDecoder.api.decode(ExamPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.today.count, 2)
        XCTAssertEqual(plan.today[0].minutes, 45.6, accuracy: 0.001)
        XCTAssertNil(plan.today[1].topic)
        let t = try XCTUnwrap(plan.targets.first)
        XCTAssertEqual(t.daysLeft, 26)
        XCTAssertEqual(t.phases.first?.planned ?? 0, 490.3175, accuracy: 0.001)
        XCTAssertEqual(t.days.first?.phases["learn"], 46)
        XCTAssertEqual(t.topics.first?.practiseMin, 30.5)
        XCTAssertEqual(t.mocks?.count, 2)
        XCTAssertEqual(plan.undated.first?.id, 7)
        XCTAssertEqual(plan.settings?.termCapMin, 120)
    }

    func testTimeWords() {
        XCTAssertEqual(PlanTime.text(45.6), "46 min")
        XCTAssertEqual(PlanTime.text(120), "2 h")
        XCTAssertEqual(PlanTime.text(135), "2 h 15")
        XCTAssertEqual(PlanTime.text(1860), "31 h")
        XCTAssertEqual(PlanTime.hours(90), "1\(Locale.current.decimalSeparator ?? ".")5 h")
        XCTAssertEqual(PlanTime.hours(1194), "20 h")
    }

    func testChangeBodies() throws {
        let enc = JSONEncoder.api
        enc.outputFormatting = .sortedKeys
        func body(_ c: PlanCourseChange) throws -> String { String(decoding: try enc.encode(c), as: UTF8.self) }
        XCTAssertEqual(try body(PlanCourseChange(field: .expected(nil))), #"{"expected":null}"#)
        XCTAssertEqual(try body(PlanCourseChange(field: .expected("2027-01-14"))), #"{"expected":"2027-01-14"}"#)
        XCTAssertEqual(try body(PlanCourseChange(field: .topics(key: "d_1", ids: nil))), #"{"key":"d_1","topics":null}"#)
        XCTAssertEqual(try body(PlanCourseChange(field: .topics(key: "d_1", ids: ["t_1"]))), #"{"key":"d_1","topics":["t_1"]}"#)
    }
}
