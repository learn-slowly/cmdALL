import XCTest
@testable import CmdMD

/// 진도 3종 계산(`StudyProgressCalculator`).
/// 설계 `docs/superpowers/specs/2026-08-02-study-progress-design.md` §진도 3종 계산.
final class StudyProgressCalculatorTests: XCTestCase {

    /// 100쪽 교재, 세 장: 1~40(40쪽) · 41~70(30쪽) · 71~100(30쪽).
    private func outline(read: [Bool] = [false, false, false]) -> StudyOutline {
        StudyOutline(unit: .page, total: 100, chapters: [
            StudyOutlineChapter(no: 1, title: "1장", start: 1, end: 40, read: read[0]),
            StudyOutlineChapter(no: 2, title: "2장", start: 41, end: 70, read: read[1]),
            StudyOutlineChapter(no: 3, title: "3장", start: 71, end: 100, read: read[2]),
        ])
    }

    private func item(page: Int, interval: Int) -> StudyIndexItem {
        StudyIndexItem(uid: UUID(), studyID: UUID(), notePath: "/n.md", kind: .card,
                       loc: .page(page), title: "t", body: "b",
                       state: StudyReviewState(due: Date(), interval: interval, ease: 2.5,
                                                reps: interval > 0 ? 1 : 0, lapses: 0),
                       lineText: "", srcPath: "/교재.pdf")
    }

    // MARK: - ① 읽음

    func testReadRatioIsWeightedByChapterLength() {
        let summary = StudyProgressCalculator.summarize(outline: outline(read: [true, false, false]), items: [])

        XCTAssertEqual(summary.readLength, 40)
        XCTAssertEqual(summary.readRatio, 0.4, accuracy: 0.0001,
                       "장 개수가 아니라 분량(쪽 수) 기준이어야 한다")
        XCTAssertEqual(summary.madeRatio, 0)
        XCTAssertEqual(summary.masteredRatio, 0)
    }

    // MARK: - ② 만듦

    func testMadeRatioCountsWholeChapterWhenAnyItemExists() {
        let summary = StudyProgressCalculator.summarize(
            outline: outline(), items: [item(page: 45, interval: 0)])

        XCTAssertEqual(summary.madeLength, 30, "2장에 하나라도 만들었으면 2장 분량 전체가 잡힌다")
        XCTAssertEqual(summary.madeRatio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(summary.chapters[1].itemCount, 1)
        XCTAssertEqual(summary.chapters[0].itemCount, 0)
    }

    func testPageRangeLocatorUsesFirstPage() {
        let ranged = StudyIndexItem(uid: UUID(), studyID: UUID(), notePath: "/n.md", kind: .card,
                                    loc: .pageRange(38, 44), title: "t", body: "b",
                                    state: .initial(), lineText: "", srcPath: "/교재.pdf")
        let summary = StudyProgressCalculator.summarize(outline: outline(), items: [ranged])

        XCTAssertEqual(summary.chapters[0].itemCount, 1, "38~44쪽은 시작 쪽(38)이 든 1장에 붙는다")
        XCTAssertEqual(summary.chapters[1].itemCount, 0)
    }

    // MARK: - ③ 익힘

    func testMasteryUsesIntervalThreshold() {
        XCTAssertTrue(StudyProgressCalculator.isMastered(
            StudyReviewState(due: Date(), interval: 21, ease: 2.5, reps: 3, lapses: 0)))
        XCTAssertFalse(StudyProgressCalculator.isMastered(
            StudyReviewState(due: Date(), interval: 20, ease: 2.5, reps: 3, lapses: 0)))
        XCTAssertFalse(StudyProgressCalculator.isMastered(.initial()))
    }

    func testMasteredRatioIsChapterLengthTimesMasteryShare() {
        // 2장(30쪽)에 4개 중 2개가 익힘 → 30 × 0.5 = 15 → 15/100
        let items = [
            item(page: 45, interval: 30), item(page: 50, interval: 25),
            item(page: 55, interval: 5), item(page: 60, interval: 0),
        ]
        let summary = StudyProgressCalculator.summarize(outline: outline(), items: items)

        XCTAssertEqual(summary.chapters[1].masteryRatio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.masteredLength, 15, accuracy: 0.0001)
        XCTAssertEqual(summary.masteredRatio, 0.15, accuracy: 0.0001)
        XCTAssertEqual(summary.masteredItemCount, 2)
        XCTAssertEqual(summary.itemCount, 4)
    }

    func testMasteredNeverExceedsMade() {
        let items = (0..<5).map { item(page: 45 + $0, interval: 180) }
        let summary = StudyProgressCalculator.summarize(outline: outline(), items: items)

        XCTAssertEqual(summary.masteredRatio, summary.madeRatio, accuracy: 0.0001,
                       "그 장을 전부 익히면 익힘은 만듦과 같아지고, 넘지 않는다")
    }

    // MARK: - 위치를 못 붙이는 항목

    func testUnknownLocatorCountsAsUnplaced() {
        let unknown = StudyIndexItem(uid: UUID(), studyID: UUID(), notePath: "/n.md", kind: .card,
                                     loc: .unknown, title: "t", body: "b", state: .initial(),
                                     lineText: "", srcPath: "/교재.hwp")
        let summary = StudyProgressCalculator.summarize(outline: outline(), items: [unknown])

        XCTAssertEqual(summary.unplacedItemCount, 1, "오피스 교재는 원본 위치를 몰라 장에 못 붙는다")
        XCTAssertEqual(summary.madeRatio, 0)
        XCTAssertEqual(summary.itemCount, 1)
    }

    func testItemOutsideAnyChapterIsUnplaced() {
        let summary = StudyProgressCalculator.summarize(outline: outline(), items: [item(page: 500, interval: 0)])
        XCTAssertEqual(summary.unplacedItemCount, 1)
    }

    func testLineLocatorNeedsLineUnit() {
        XCTAssertEqual(StudyProgressCalculator.position(of: .line(9), unit: .line), 9)
        XCTAssertNil(StudyProgressCalculator.position(of: .line(9), unit: .page),
                     "쪽 단위 교재에 줄 위치를 섞으면 붙이지 않는다")
        XCTAssertNil(StudyProgressCalculator.position(of: .page(9), unit: .section))
    }

    // MARK: - 경계

    func testEmptyOutlineGivesZeroRatiosWithoutCrash() {
        let summary = StudyProgressCalculator.summarize(
            outline: StudyOutline(unit: .page, total: 0, chapters: []), items: [item(page: 1, interval: 30)])

        XCTAssertEqual(summary.readRatio, 0)
        XCTAssertEqual(summary.madeRatio, 0)
        XCTAssertEqual(summary.masteredRatio, 0)
        XCTAssertEqual(summary.unplacedItemCount, 1)
    }

    func testFullyReadAndFullyMasteredReachesOne() {
        let items = [item(page: 10, interval: 60), item(page: 45, interval: 60), item(page: 80, interval: 60)]
        let summary = StudyProgressCalculator.summarize(outline: outline(read: [true, true, true]), items: items)

        XCTAssertEqual(summary.readRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.madeRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.masteredRatio, 1.0, accuracy: 0.0001)
    }
}
