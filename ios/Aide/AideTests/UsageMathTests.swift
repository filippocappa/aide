import XCTest
@testable import Aide

final class UsageMathTests: XCTestCase {
    private let calendar = Calendar.current
    private let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_793_000_000))

    private func day(_ offset: Int, hours: [Int: Double], pickups: Int = 0) -> UsageDay {
        let date = calendar.date(byAdding: .day, value: offset, to: today)!
        var hourly = Array(repeating: TimeInterval(0), count: 24)
        for (h, minutes) in hours { hourly[h] = minutes * 60 }
        var app = UsageApp(id: "a", name: "A", seconds: hourly.reduce(0, +), pickups: pickups, hourly: hourly)
        app.notifications = 0
        return UsageDay(date: date, apps: [app])
    }

    func testTotalIsTheAppsSum() {
        var d = UsageDay(date: today)
        d.apps = [UsageApp(id: "a", name: "A", seconds: 600, pickups: 3), UsageApp(id: "b", name: "B", seconds: 1200, pickups: 2)]
        XCTAssertEqual(d.total, 1800)
        XCTAssertEqual(d.pickups, 5)
        XCTAssertEqual(d.ranked.map(\.id), ["b", "a"])
    }

    func testTotalBeforeCountsTheCurrentHourInProportion() {
        let d = day(0, hours: [8: 30, 9: 60])
        XCTAssertEqual(d.total(before: 9.5 * 3600), 30 * 60 + 30 * 60, accuracy: 0.1)
        XCTAssertEqual(d.total(before: 8 * 3600), 0)
    }

    func testUsualNeedsThreeDaysAndMatchesTheHour() {
        let past = [day(-1, hours: [8: 20, 20: 60]), day(-2, hours: [8: 40, 20: 60])]
        let d = day(0, hours: [8: 30])
        XCTAssertNil(UsageMath.usual(before: d, in: past + [d]))
        let more = past + [day(-3, hours: [8: 30, 20: 60]), d]
        XCTAssertEqual(UsageMath.usual(before: d, in: more)!, 90 * 60, accuracy: 0.1)
        XCTAssertEqual(UsageMath.usual(before: d, in: more, by: 9 * 3600)!, 30 * 60, accuracy: 0.1)
    }

    func testFocusScoresLightDaysHigherThanHeavyOnes() {
        let past = (1...5).map { day(-$0, hours: [12: 60, 20: 60], pickups: 40) }
        let light = day(0, hours: [12: 30], pickups: 10)
        let heavy = day(0, hours: [12: 60, 20: 60, 21: 60, 22: 60, 23: 60, 1: 60], pickups: 120)
        let lightFocus = UsageMath.focus(light, in: past + [light], now: today.addingTimeInterval(86400 * 2))
        let heavyFocus = UsageMath.focus(heavy, in: past + [heavy], now: today.addingTimeInterval(86400 * 2))
        XCTAssertEqual(lightFocus.score, 100)
        XCTAssertLessThan(heavyFocus.score, 40)
        XCTAssertEqual(lightFocus.parts.map(\.name), ["How much", "Against your usual", "Pickups", "At night"])
    }

    func testOfflineIsTheTimeSinceTheFirstPickupLessTheUse() {
        var d = day(-1, hours: [8: 30, 21: 30])
        d.firstPickup = d.date.addingTimeInterval(8 * 3600)
        // Until the end of 21:00's hour: 14 hours, less an hour used.
        XCTAssertEqual(UsageMath.offline(d, now: today)!, 13 * 3600, accuracy: 0.1)
    }

    func testPeriodsAndWhatTheyAreComparedWith() {
        let week = UsageMath.period(.week, containing: today)
        XCTAssertEqual(UsageMath.days(of: week).count, 7)
        XCTAssertEqual(UsageMath.asked(.week, containing: today).duration, 14 * 86400, accuracy: 7200)
        XCTAssertEqual(UsageMath.days(of: UsageMath.asked(.day, containing: today)).count, 15)
    }

    func testAverageLeavesOutTheDayInProgress() {
        let now = today.addingTimeInterval(3600)
        let days = [day(-2, hours: [12: 120]), day(-1, hours: [12: 60]), day(0, hours: [0: 2])]
        XCTAssertEqual(UsageMath.average(days, now: now)!, 90 * 60, accuracy: 0.1)
        XCTAssertEqual(UsageMath.average([days[2]], now: now)!, 2 * 60, accuracy: 0.1)
    }

    func testDurations() {
        XCTAssertEqual(UsageMath.duration(0), "0m")
        XCTAssertEqual(UsageMath.duration(38 * 60), "38m")
        XCTAssertEqual(UsageMath.duration(2 * 3600), "2h")
        XCTAssertEqual(UsageMath.duration(4 * 3600 + 12 * 60), "4h 12m")
    }
}
