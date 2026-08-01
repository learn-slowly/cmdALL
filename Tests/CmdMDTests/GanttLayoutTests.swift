import XCTest
@testable import CmdMD

/// 할일 목록 "간트차트" — `GanttLayout`이 §레고 결정("오늘~마감일로 이어지는 막대·전체 범위는
/// 가장 늦은 마감일까지 자동")을 정확히 계산하는지 확인한다. 전부 순수 함수.
final class GanttLayoutTests: XCTestCase {
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: base))!
    }

    private let today = Date(timeIntervalSince1970: 1_754_000_000)   // 2026-08-01 근처, 결정적 테스트용.

    // MARK: - rangeEnd

    func testRangeEndPicksLatestFutureDate() {
        let dates = [day(2, from: today), day(10, from: today), day(5, from: today)]
        let end = GanttLayout.rangeEnd(dueDates: dates, today: today)
        XCTAssertEqual(end, calendar.startOfDay(for: day(10, from: today)))
    }

    func testRangeEndFallsBackToTodayWhenAllPast() {
        let dates = [day(-3, from: today), day(-1, from: today)]
        let end = GanttLayout.rangeEnd(dueDates: dates, today: today)
        XCTAssertEqual(end, calendar.startOfDay(for: today))
    }

    func testRangeEndFallsBackToTodayWhenEmpty() {
        let end = GanttLayout.rangeEnd(dueDates: [], today: today)
        XCTAssertEqual(end, calendar.startOfDay(for: today))
    }

    func testRangeEndIncludesTodayItself() {
        let dates = [calendar.startOfDay(for: today)]
        let end = GanttLayout.rangeEnd(dueDates: dates, today: today)
        XCTAssertEqual(end, calendar.startOfDay(for: today))
    }

    // MARK: - barFraction

    func testBarFractionAtRangeEndIsOne() {
        let rangeEnd = day(10, from: today)
        let fraction = GanttLayout.barFraction(today: today, due: rangeEnd, rangeEnd: rangeEnd)
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    func testBarFractionDueTodayIsZero() {
        let rangeEnd = day(10, from: today)
        let fraction = GanttLayout.barFraction(today: today, due: today, rangeEnd: rangeEnd)
        XCTAssertEqual(fraction, 0.0, accuracy: 0.0001)
    }

    func testBarFractionIsProportionalInBetween() {
        let rangeEnd = day(10, from: today)
        let due = day(5, from: today)
        let fraction = GanttLayout.barFraction(today: today, due: due, rangeEnd: rangeEnd)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.0001)
    }

    func testBarFractionOverdueIsZero() {
        let rangeEnd = day(10, from: today)
        let due = day(-2, from: today)
        let fraction = GanttLayout.barFraction(today: today, due: due, rangeEnd: rangeEnd)
        XCTAssertEqual(fraction, 0.0, accuracy: 0.0001)
    }

    func testBarFractionWhenRangeIsSingleDayReturnsOne() {
        // 오늘 마감인 할일 하나뿐이면 rangeEnd == today(totalDays == 0) — 0으로 나누면 안 된다.
        let fraction = GanttLayout.barFraction(today: today, due: today, rangeEnd: today)
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    func testBarFractionClampsAtOneEvenIfDueBeyondRangeEnd() {
        // 방어적 클램프 — 정상 사용에선 안 나오는 입력이지만 UI가 범위 밖으로 안 새게.
        let rangeEnd = day(5, from: today)
        let due = day(20, from: today)
        let fraction = GanttLayout.barFraction(today: today, due: due, rangeEnd: rangeEnd)
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - isOverdue

    func testIsOverdueYesterdayIsTrue() {
        XCTAssertTrue(GanttLayout.isOverdue(due: day(-1, from: today), today: today))
    }

    func testIsOverdueTodayIsFalse() {
        XCTAssertFalse(GanttLayout.isOverdue(due: today, today: today))
    }

    func testIsOverdueTomorrowIsFalse() {
        XCTAssertFalse(GanttLayout.isOverdue(due: day(1, from: today), today: today))
    }
}
