import XCTest
@testable import CmdMD

/// S1 셋째 조각 — `StudyChunker`가 위치 태그·구분자를 포함해 예산을 지키고, 조각 경계를
/// 보존하며, 강제 분할 시 위치를 승계하는지 확인한다(설계 §5.1·§5.3·§4.2.5).
final class StudyChunkerTests: XCTestCase {

    func testEmptyInputReturnsNoChunks() {
        XCTAssertTrue(StudyChunker.chunks(from: [], budget: 1000).isEmpty)
    }

    func testNonPositiveBudgetReturnsNoChunks() {
        let segments = [StudySegment(text: "본문", locator: .page(1))]

        XCTAssertTrue(StudyChunker.chunks(from: segments, budget: 0).isEmpty)
        XCTAssertTrue(StudyChunker.chunks(from: segments, budget: -5).isEmpty)
    }

    func testSingleSegmentIsTaggedWithLocatorPrefix() {
        let segments = [StudySegment(text: "AAAA", locator: .page(1))]

        let chunks = StudyChunker.chunks(from: segments, budget: 100)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].body, "[[p1]] AAAA")
        XCTAssertEqual(chunks[0].coveredLocators, [.page(1)])
        XCTAssertEqual(chunks[0].charCount, chunks[0].body.count)
    }

    func testLineAndUnknownLocatorsUseExpectedTagFormat() {
        let segments = [
            StudySegment(text: "글", locator: .line(345)),
            StudySegment(text: "글2", locator: .unknown),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 1000)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].body.contains("[[l345]] 글"))
        XCTAssertTrue(chunks[0].body.contains("[[?]] 글2"))
    }

    // MARK: - 경계 보존(헤딩·페이지) — 예산이 넉넉하면 한 청크로 합치되 태그는 각자 유지

    func testMultipleSegmentsMergeIntoOneChunkWhenBudgetAllows() {
        // "[[p1]] AAAA" = 11자, "[[p2]] BBBB" = 11자, 구분자(\n\n) 2자 → 합쳐서 24자.
        let segments = [
            StudySegment(text: "AAAA", locator: .page(1)),
            StudySegment(text: "BBBB", locator: .page(2)),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 24)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].coveredLocators, [.page(1), .page(2)])
        XCTAssertEqual(chunks[0].body, "[[p1]] AAAA\n\n[[p2]] BBBB")
    }

    func testSegmentsSplitIntoSeparateChunksWhenTheyDoNotFitTogether() {
        // 각 태그+본문은 11자 — 둘을 합치면 24자라 23자 예산엔 못 들어가고 청크가 갈린다.
        let segments = [
            StudySegment(text: "AAAA", locator: .page(1)),
            StudySegment(text: "BBBB", locator: .page(2)),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 23)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].coveredLocators, [.page(1)])
        XCTAssertEqual(chunks[0].body, "[[p1]] AAAA")
        XCTAssertEqual(chunks[1].coveredLocators, [.page(2)])
        XCTAssertEqual(chunks[1].body, "[[p2]] BBBB")
    }

    func testThreeSegmentsPackGreedilyInOrder() {
        // 11자짜리 셋 — 예산 24면 처음 둘만 한 청크(24자), 셋째는 새 청크.
        let segments = [
            StudySegment(text: "AAAA", locator: .page(1)),
            StudySegment(text: "BBBB", locator: .page(2)),
            StudySegment(text: "CCCC", locator: .page(3)),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 24)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].coveredLocators, [.page(1), .page(2)])
        XCTAssertEqual(chunks[1].coveredLocators, [.page(3)])
    }

    // MARK: - 강제 분할 + locator 승계

    func testOversizedSegmentIsForceSplitAndInheritsSameLocator() {
        let longText = String(repeating: "가", count: 50)
        let segments = [StudySegment(text: longText, locator: .line(10))]

        // 태그 "[[l10]] "(8자) + 본문 → budget 20이면 조각당 본문 12자(20-8), 50자를 5개로.
        let chunks = StudyChunker.chunks(from: segments, budget: 20)

        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.coveredLocators == [.line(10)] }, "강제 분할된 조각도 원래 위치를 그대로 물려받아야 한다")
        XCTAssertTrue(chunks.allSatisfy { $0.charCount <= 20 })
        // 분할된 본문을 이어붙이면 원문과 같아야 한다(글자 손실·중복 없음).
        let recombined = chunks.map { $0.body.replacingOccurrences(of: "[[l10]] ", with: "") }.joined()
        XCTAssertEqual(recombined, longText)
    }

    func testForceSplitOnlyAffectsTheOversizedSegmentNotItsNeighbors() {
        let longText = String(repeating: "나", count: 30)
        let segments = [
            StudySegment(text: "짧다", locator: .page(1)),
            StudySegment(text: longText, locator: .line(5)),
            StudySegment(text: "짧다2", locator: .page(2)),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 15)

        // 첫 조각은 그대로 한 청크, 가운데는 강제 분할로 여러 청크, 마지막도 별도 청크.
        XCTAssertEqual(chunks.first?.coveredLocators, [.page(1)])
        XCTAssertEqual(chunks.last?.coveredLocators, [.page(2)])
        XCTAssertTrue(chunks.dropFirst().dropLast().allSatisfy { $0.coveredLocators == [.line(5)] })
        XCTAssertGreaterThan(chunks.count, 3, "가운데 조각이 여러 청크로 갈렸어야 한다")
    }

    func testExtremelyTinyBudgetDoesNotCrashOrLoopForever() {
        // budget이 태그 길이보다도 작은 병적인 값 — 크래시·무한루프 없이 유한 개로 끝나야 한다.
        let segments = [StudySegment(text: String(repeating: "X", count: 20), locator: .page(999))]

        let chunks = StudyChunker.chunks(from: segments, budget: 1)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertLessThanOrEqual(chunks.count, 20, "1글자씩만 나가도 20개를 넘을 수 없다")
    }

    // MARK: - coveredLocators로 청크 밖 인용 판별(§5.3의 전제)

    func testCoveredLocatorsCanBeUsedToDetectOutOfChunkCitation() {
        let segments = [
            StudySegment(text: "본문1", locator: .page(1)),
            StudySegment(text: "본문2", locator: .page(2)),
        ]

        let chunks = StudyChunker.chunks(from: segments, budget: 12) // 둘이 못 합쳐지게 좁게.

        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].coveredLocators.contains(.page(1)))
        XCTAssertFalse(chunks[0].coveredLocators.contains(.page(2)), "다른 청크의 위치를 인용하면 청크 밖 인용으로 잡혀야 한다")
    }
}
