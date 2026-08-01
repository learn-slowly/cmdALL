import XCTest
@testable import CmdMD

/// 학습도우미 복습(S2) — `ReviewScheduler.grade(_:outcome:now:)`가 §3.9 공식(경계값 포함)을
/// 정확히 따르는지 확인한다. 순수 함수라 디스크·시간 흐름을 관찰하지 않는다.
final class ReviewSchedulerTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_750_000_000) // 결정적 테스트용 고정 시각.

    private func startOfFixedDay() -> Date {
        Calendar.current.startOfDay(for: fixedNow)
    }

    // MARK: - 모름

    func testForgotResetsIntervalAndReps() {
        let state = StudyReviewState(due: fixedNow, interval: 20, ease: 2.30, reps: 3, lapses: 1)
        let next = ReviewScheduler.grade(state, outcome: .forgot, now: fixedNow)
        XCTAssertEqual(next.interval, 1)
        XCTAssertEqual(next.reps, 0)
        XCTAssertEqual(next.lapses, 2)
        XCTAssertEqual(next.ease, 2.10, accuracy: 0.0001)
        XCTAssertEqual(next.due, Calendar.current.date(byAdding: .day, value: 1, to: startOfFixedDay()))
    }

    func testForgotClampsEaseAtLowerBound() {
        let state = StudyReviewState(due: fixedNow, interval: 5, ease: 1.35, reps: 2, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .forgot, now: fixedNow)
        XCTAssertEqual(next.ease, ReviewScheduler.easeRange.lowerBound, accuracy: 0.0001)
    }

    // MARK: - 애매

    func testUnsureGrowsIntervalByFactorAndLowersEaseSlightly() {
        let state = StudyReviewState(due: fixedNow, interval: 10, ease: 2.50, reps: 3, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .unsure, now: fixedNow)
        XCTAssertEqual(next.interval, 12)   // round(10 × 1.2) = 12
        XCTAssertEqual(next.ease, 2.45, accuracy: 0.0001)
        XCTAssertEqual(next.reps, 3, "애매는 reps를 건드리지 않는다(스펙 공식이 reps를 참조하지 않음)")
        XCTAssertEqual(next.lapses, 0)
    }

    func testUnsureFloorsAtOneDay() {
        let state = StudyReviewState(due: fixedNow, interval: 0, ease: 2.50, reps: 0, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .unsure, now: fixedNow)
        XCTAssertEqual(next.interval, 1)
    }

    // MARK: - 앎 — 첫 성공 1일 · 두 번째 3일 · 그 이후 공식

    func testKnewFirstSuccessSetsOneDayInterval() {
        let state = StudyReviewState.initial(now: fixedNow)   // reps == 0
        let next = ReviewScheduler.grade(state, outcome: .knew, now: fixedNow)
        XCTAssertEqual(next.interval, 1)
        XCTAssertEqual(next.reps, 1)
        XCTAssertEqual(next.ease, 2.55, accuracy: 0.0001)
    }

    func testKnewSecondSuccessSetsThreeDayInterval() {
        let state = StudyReviewState(due: fixedNow, interval: 1, ease: 2.55, reps: 1, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .knew, now: fixedNow)
        XCTAssertEqual(next.interval, 3)
        XCTAssertEqual(next.reps, 2)
    }

    func testKnewThirdSuccessUsesEaseFormula() {
        let state = StudyReviewState(due: fixedNow, interval: 3, ease: 2.60, reps: 2, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .knew, now: fixedNow)
        XCTAssertEqual(next.interval, 8)   // round(3 × 2.60) = round(7.8) = 8
        XCTAssertEqual(next.reps, 3)
    }

    func testKnewClampsEaseAtUpperBound() {
        let state = StudyReviewState(due: fixedNow, interval: 30, ease: 2.78, reps: 5, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .knew, now: fixedNow)
        XCTAssertEqual(next.ease, ReviewScheduler.easeRange.upperBound, accuracy: 0.0001)
    }

    func testKnewClampsIntervalAt180Days() {
        let state = StudyReviewState(due: fixedNow, interval: 170, ease: 2.80, reps: 5, lapses: 0)
        let next = ReviewScheduler.grade(state, outcome: .knew, now: fixedNow)
        XCTAssertEqual(next.interval, ReviewScheduler.maxIntervalDays)
    }

    // MARK: - due는 항상 오늘(자정 기준) + 새 interval

    func testDueIsAlwaysStartOfDayPlusNewInterval() {
        // now에 시·분·초가 섞여 있어도 결과 due는 자정 기준이어야 한다(날짜 비교의 안정성).
        let messyNow = fixedNow.addingTimeInterval(3 * 3600 + 47 * 60)
        let state = StudyReviewState.initial(now: messyNow)
        let next = ReviewScheduler.grade(state, outcome: .knew, now: messyNow)
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: messyNow))
        XCTAssertEqual(next.due, expected)
    }

    // MARK: - 결정성

    func testSameInputSameOutcomeAlwaysProducesSameResult() {
        let state = StudyReviewState(due: fixedNow, interval: 7, ease: 2.20, reps: 2, lapses: 1)
        let a = ReviewScheduler.grade(state, outcome: .unsure, now: fixedNow)
        let b = ReviewScheduler.grade(state, outcome: .unsure, now: fixedNow)
        XCTAssertEqual(a, b)
    }
}
