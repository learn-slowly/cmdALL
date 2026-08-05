import XCTest
@testable import CmdMD

/// 문제집 기록장(Q2) — 원본은 손대지 않고 문항 번호 + 복습 상태만 남기는 파일.
final class QuizRecordNoteTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/tmp/볼트/문제집기록", isDirectory: true)
    private let source = URL(fileURLWithPath: "/tmp/볼트/100제/문제집_1.1.1_100문항.md")
    private let book = URL(fileURLWithPath: "/tmp/볼트/100제/교재.pdf")

    private func makeNote(count: Int = 3, now: Date = Date()) -> String {
        QuizRecordNote.build(sourceURL: source, bookURL: book, itemCount: count,
                             noteFolder: folder, now: now)
    }

    // MARK: - 만들기 · 읽기

    func testBuildsOneAnchorPerQuestion() throws {
        let note = makeNote(count: 3)
        let parsed = try XCTUnwrap(QuizRecordNote.parse(note))

        XCTAssertEqual(parsed.itemCount, 3)
        XCTAssertEqual(parsed.records.map(\.n), [1, 2, 3])
        XCTAssertEqual(parsed.records[0].state.interval, 0)
        XCTAssertEqual(parsed.records[0].state.reps, 0)
        // 원본·교재 경로가 상대경로로 남는다(볼트를 통째로 옮겨도 따라간다).
        XCTAssertTrue(parsed.source.contains("100"))
        XCTAssertNotNil(parsed.book)
    }

    /// 문제 내용은 기록장에 없어야 한다 — 있으면 정답이 두 곳에 적히는 것이다.
    func testNoteCarriesNoQuestionContent() {
        let note = makeNote(count: 2)
        for marker in ["Q:", "A:", "해설:", "1)", "①"] {
            XCTAssertFalse(note.contains(marker), "기록장에 문제 내용이 들어갔다: \(marker)")
        }
    }

    func testBookIsOptional() throws {
        let note = QuizRecordNote.build(sourceURL: source, bookURL: nil, itemCount: 1,
                                        noteFolder: folder)
        let parsed = try XCTUnwrap(QuizRecordNote.parse(note))
        XCTAssertNil(parsed.book)
    }

    func testParseRejectsUnrelatedMarkdown() {
        XCTAssertNil(QuizRecordNote.parse("# 그냥 노트\n\n본문"))
    }

    // MARK: - 앵커 왕복

    func testAnchorRoundTrip() throws {
        let state = StudyReviewState(due: Date(timeIntervalSince1970: 1_800_000_000),
                                     interval: 12, ease: 2.35, reps: 4, lapses: 1)
        let line = QuizRecordNote.formatAnchorLine(QuizRecord(n: 7, state: state))
        let back = try XCTUnwrap(QuizRecordNote.parseAnchorLine(line))

        XCTAssertEqual(back.n, 7)
        XCTAssertEqual(back.state.interval, 12)
        XCTAssertEqual(back.state.ease, 2.35, accuracy: 0.001)
        XCTAssertEqual(back.state.reps, 4)
        XCTAssertEqual(back.state.lapses, 1)
    }

    /// 알 수 없는 키는 잃지 않고 그대로 돌려준다(사용자·후속 버전이 더한 값 보존).
    func testUnknownKeysArePreserved() throws {
        let raw = "<!-- quiz n=2 due=2026-08-05 ivl=0 ease=2.50 reps=0 lapses=0 mine=abc -->"
        let record = try XCTUnwrap(QuizRecordNote.parseAnchorLine(raw))
        XCTAssertEqual(record.extraTokens, ["mine=abc"])
        XCTAssertTrue(QuizRecordNote.formatAnchorLine(record).contains("mine=abc"))
    }

    func testMalformedAnchorIsIgnored() {
        XCTAssertNil(QuizRecordNote.parseAnchorLine("<!-- quiz n=1 due -->"))
        XCTAssertNil(QuizRecordNote.parseAnchorLine("<!-- outline no=1 start=1 end=2 read=no -->"))
        XCTAssertNil(QuizRecordNote.parseAnchorLine("보통 글줄"))
    }

    // MARK: - 채점 쓰기

    func testReplacingAnchorLineUpdatesOnlyThatQuestion() throws {
        let note = makeNote(count: 3)
        let before = try XCTUnwrap(QuizRecordNote.parse(note))
        let target = try XCTUnwrap(before.records.first { $0.n == 2 })
        let expected = QuizRecordNote.formatAnchorLine(target)
        let graded = ReviewScheduler.grade(target.state, outcome: .knew)

        let updated = try XCTUnwrap(QuizRecordNote.replacingAnchorLine(
            in: note, number: 2, expectedLineText: expected, newState: graded))
        let after = try XCTUnwrap(QuizRecordNote.parse(updated))

        XCTAssertEqual(after.records.first { $0.n == 2 }?.state.reps, 1)
        // 나머지 문항은 한 글자도 안 바뀐다.
        XCTAssertEqual(after.records.first { $0.n == 1 }, before.records.first { $0.n == 1 })
        XCTAssertEqual(after.records.first { $0.n == 3 }, before.records.first { $0.n == 3 })
    }

    /// 그 사이 파일이 바뀌었으면 포기한다(복습 채점과 같은 규약).
    func testReplacingFailsWhenLineChangedMeanwhile() {
        let note = makeNote(count: 2)
        let stale = "<!-- quiz n=1 due=2000-01-01 ivl=99 ease=2.50 reps=9 lapses=9 -->"
        XCTAssertNil(QuizRecordNote.replacingAnchorLine(
            in: note, number: 1, expectedLineText: stale, newState: .initial()))
    }

    func testReplacingUnknownNumberFails() {
        let note = makeNote(count: 2)
        XCTAssertNil(QuizRecordNote.replacingAnchorLine(
            in: note, number: 99, expectedLineText: "아무거나", newState: .initial()))
    }

    // MARK: - 원본 문항 수가 달라졌을 때

    func testReconcilingAddsNewQuestions() throws {
        let note = makeNote(count: 2)
        let updated = try XCTUnwrap(QuizRecordNote.reconciling(content: note, itemCount: 4))
        let parsed = try XCTUnwrap(QuizRecordNote.parse(updated))

        XCTAssertEqual(parsed.records.map(\.n), [1, 2, 3, 4])
        XCTAssertEqual(parsed.itemCount, 4)
    }

    /// 원본에서 사라진 번호의 기록은 지우지 않는다(되돌릴 수 없는 삭제를 하지 않는다).
    func testReconcilingKeepsRecordsOfRemovedQuestions() throws {
        var note = makeNote(count: 3)
        let target = try XCTUnwrap(QuizRecordNote.parse(note)?.records.first { $0.n == 3 })
        note = try XCTUnwrap(QuizRecordNote.replacingAnchorLine(
            in: note, number: 3, expectedLineText: QuizRecordNote.formatAnchorLine(target),
            newState: ReviewScheduler.grade(target.state, outcome: .forgot)))

        // 원본이 2문항으로 줄어도 3번 기록은 남는다.
        XCTAssertNil(QuizRecordNote.reconciling(content: note, itemCount: 2))
        let parsed = try XCTUnwrap(QuizRecordNote.parse(note))
        XCTAssertEqual(parsed.records.map(\.n), [1, 2, 3])
        XCTAssertEqual(parsed.records.first { $0.n == 3 }?.state.lapses, 1)
    }

    func testReconcilingReturnsNilWhenNothingToDo() {
        let note = makeNote(count: 3)
        XCTAssertNil(QuizRecordNote.reconciling(content: note, itemCount: 3))
    }

    /// 이미 풀어 둔 기록은 문항이 늘어나도 그대로다.
    func testReconcilingPreservesExistingProgress() throws {
        var note = makeNote(count: 2)
        let target = try XCTUnwrap(QuizRecordNote.parse(note)?.records.first { $0.n == 1 })
        note = try XCTUnwrap(QuizRecordNote.replacingAnchorLine(
            in: note, number: 1, expectedLineText: QuizRecordNote.formatAnchorLine(target),
            newState: ReviewScheduler.grade(target.state, outcome: .knew)))

        let updated = try XCTUnwrap(QuizRecordNote.reconciling(content: note, itemCount: 5))
        let parsed = try XCTUnwrap(QuizRecordNote.parse(updated))
        XCTAssertEqual(parsed.records.first { $0.n == 1 }?.state.reps, 1)
        XCTAssertEqual(parsed.records.map(\.n), [1, 2, 3, 4, 5])
    }

    // MARK: - 파일 이름

    func testFileNameFollowsSource() {
        XCTAssertEqual(QuizRecordNote.fileName(for: source), "문제집_1.1.1_100문항.md")
    }
}
