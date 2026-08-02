import XCTest
@testable import CmdMD

/// 진도 노트 파일 읽기·쓰기(`StudyProgressNote`).
/// 설계 `docs/superpowers/specs/2026-08-02-study-progress-design.md` §진실의 출처.
final class StudyProgressNoteTests: XCTestCase {

    private let noteFolder = URL(fileURLWithPath: "/tmp/볼트/진도", isDirectory: true)
    private let sourceURL = URL(fileURLWithPath: "/tmp/볼트/교재/미디어교육사 교재.pdf")

    private func sampleOutline() -> StudyOutline {
        StudyOutline(unit: .page, total: 562, chapters: [
            StudyOutlineChapter(no: 1, title: "머리말", start: 1, end: 6),
            StudyOutlineChapter(no: 2, title: "1.1.1. 미디어 개념과 특징", start: 7, end: 31),
            StudyOutlineChapter(no: 3, title: "1.1.2. 미디어 산업의 구조와 특성(영향력)", start: 32, end: 562),
        ])
    }

    private func sampleNote(now: Date = Date()) -> String {
        StudyProgressNote.build(outline: sampleOutline(), sourceURL: sourceURL, sourceKind: .pdf,
                                noteFolder: noteFolder, pageOffset: -1, now: now)
    }

    // MARK: - 쓰고 다시 읽기

    func testBuildAndParseRoundTrip() throws {
        let parsed = try XCTUnwrap(StudyProgressNote.parse(sampleNote()))

        XCTAssertEqual(parsed.unit, .page)
        XCTAssertEqual(parsed.total, 562)
        XCTAssertEqual(parsed.pageOffset, -1)
        XCTAssertEqual(parsed.sourceKind, .pdf)
        XCTAssertEqual(parsed.chapters.map(\.no), [1, 2, 3])
        XCTAssertEqual(parsed.chapters.map(\.start), [1, 7, 32])
        XCTAssertEqual(parsed.chapters.map(\.end), [6, 31, 562])
        XCTAssertEqual(parsed.chapters.map(\.read), [false, false, false])
    }

    func testTitleWithParenthesisSurvivesRoundTrip() throws {
        let parsed = try XCTUnwrap(StudyProgressNote.parse(sampleNote()))
        XCTAssertEqual(parsed.chapters[2].title, "1.1.2. 미디어 산업의 구조와 특성(영향력)",
                       "제목 안의 괄호를 범위 꼬리표로 착각해 잘라내면 안 된다")
    }

    func testSourcePathIsRelativeAndPercentEncoded() throws {
        let parsed = try XCTUnwrap(StudyProgressNote.parse(sampleNote()))
        XCTAssertTrue(parsed.source.hasPrefix("../"), "노트 폴더 기준 상대경로여야 한다: \(parsed.source)")
        XCTAssertEqual(parsed.source.removingPercentEncoding, "../교재/미디어교육사 교재.pdf")
    }

    func testProgressNoteIsNotPickedUpByReviewIndex() {
        // 진도 노트에는 study_id가 없으므로 복습 캐시가 항목 0건으로 걸러낸다(§3.7).
        let parsedAsStudyNote = StudyNoteParser.parse(sampleNote())
        XCTAssertNil(parsedAsStudyNote.studyID)
        XCTAssertTrue(parsedAsStudyNote.items.isEmpty)
    }

    // MARK: - 읽음 표시

    func testReplacingReadFlagMarksOnlyThatChapter() throws {
        let today = try XCTUnwrap(StudyNoteWriter.parseDay("2026-08-02"))
        let updated = try XCTUnwrap(
            StudyProgressNote.replacingReadFlag(in: sampleNote(), chapterNo: 2, read: true, now: today))
        let parsed = try XCTUnwrap(StudyProgressNote.parse(updated))

        XCTAssertEqual(parsed.chapters.map(\.read), [false, true, false])
        XCTAssertEqual(parsed.chapters[1].done, today)
        XCTAssertEqual(parsed.chapters[0].done, nil)
    }

    func testUncheckingClearsDoneDate() throws {
        let note = sampleNote()
        let checked = try XCTUnwrap(StudyProgressNote.replacingReadFlag(in: note, chapterNo: 1, read: true))
        let unchecked = try XCTUnwrap(StudyProgressNote.replacingReadFlag(in: checked, chapterNo: 1, read: false))
        let parsed = try XCTUnwrap(StudyProgressNote.parse(unchecked))

        XCTAssertFalse(parsed.chapters[0].read)
        XCTAssertNil(parsed.chapters[0].done)
    }

    func testReplacingReadFlagWithUnknownChapterReturnsNil() {
        XCTAssertNil(StudyProgressNote.replacingReadFlag(in: sampleNote(), chapterNo: 99, read: true))
    }

    // MARK: - 목차 다시 읽기(읽음 표시 이어받기)

    func testReplacingOutlineCarriesReadFlagsByChapterNumber() throws {
        let checked = try XCTUnwrap(StudyProgressNote.replacingReadFlag(in: sampleNote(), chapterNo: 2, read: true))
        let newOutline = StudyOutline(unit: .page, total: 600, chapters: [
            StudyOutlineChapter(no: 1, title: "머리말", start: 1, end: 9),
            StudyOutlineChapter(no: 2, title: "1장 새 제목", start: 10, end: 600),
        ])

        let updated = try XCTUnwrap(
            StudyProgressNote.replacingOutline(in: checked, with: newOutline, pageOffset: 3))
        let parsed = try XCTUnwrap(StudyProgressNote.parse(updated))

        XCTAssertEqual(parsed.total, 600)
        XCTAssertEqual(parsed.pageOffset, 3)
        XCTAssertEqual(parsed.chapters.map(\.title), ["머리말", "1장 새 제목"])
        XCTAssertTrue(parsed.chapters[1].read, "목차를 다시 읽어도 이미 읽은 표시는 잃지 않는다")
        XCTAssertEqual(parsed.progressID, StudyProgressNote.parse(checked)?.progressID,
                       "노트 고유 번호는 그대로 유지된다")
    }

    // MARK: - 장 직접 추가(목차 없는 교재)

    func testInsertingChapterRenumbersAndRecalculatesEnds() {
        let outline = StudyOutline(unit: .page, total: 100, chapters: [
            StudyOutlineChapter(no: 1, title: "전체", start: 1, end: 100, read: true),
        ])
        let updated = StudyProgressNote.inserting(title: "2장", start: 40, into: outline)

        XCTAssertEqual(updated.chapters.map(\.no), [1, 2])
        XCTAssertEqual(updated.chapters.map(\.title), ["전체", "2장"])
        XCTAssertEqual(updated.chapters.map(\.start), [1, 40])
        XCTAssertEqual(updated.chapters.map(\.end), [39, 100])
        XCTAssertTrue(updated.chapters[0].read, "이미 읽은 표시는 유지")
    }

    func testInsertingOutOfRangeChapterIsIgnored() {
        let outline = StudyOutline(unit: .page, total: 50, chapters: [
            StudyOutlineChapter(no: 1, title: "전체", start: 1, end: 50),
        ])
        let updated = StudyProgressNote.inserting(title: "범위 밖", start: 999, into: outline)
        XCTAssertEqual(updated.chapters.map(\.title), ["전체"])
    }

    // MARK: - 앵커 문법

    func testUnknownAnchorKeysArePreserved() throws {
        let line = "<!-- outline no=1 start=1 end=10 read=yes done=2026-08-02 mine=abc -->"
        let chapter = try XCTUnwrap(StudyProgressNote.parseAnchorLine(line))

        XCTAssertEqual(chapter.extraTokens, ["mine=abc"])
        XCTAssertTrue(StudyProgressNote.formatAnchorLine(chapter).hasSuffix("mine=abc -->"),
                      "모르는 키도 그대로 되돌려 적는다(사용자 수기 편집 보호)")
    }

    func testMalformedAnchorLinesAreRejected() {
        XCTAssertNil(StudyProgressNote.parseAnchorLine("<!-- study item=x -->"))
        XCTAssertNil(StudyProgressNote.parseAnchorLine("## 그냥 제목"))
        XCTAssertNil(StudyProgressNote.parseAnchorLine("<!-- outline start=1 end=2 read=no -->"),
                     "번호(no)가 없으면 무효")
        XCTAssertNil(StudyProgressNote.parseAnchorLine("<!-- outline no=1 잘못된토큰 -->"))
    }

    func testTitleFromHeadingStripsRangeSuffixOnly() {
        XCTAssertEqual(StudyProgressNote.title(fromHeading: "## 머리말 (1~6쪽)"), "머리말")
        XCTAssertEqual(StudyProgressNote.title(fromHeading: "## 1장 (총론) (7~31쪽)"), "1장 (총론)")
        XCTAssertNil(StudyProgressNote.title(fromHeading: "그냥 본문"))
    }

    func testParseRejectsNoteWithoutProgressID() {
        XCTAssertNil(StudyProgressNote.parse("---\nstudy_id: x\n---\n# 카드 노트\n"))
    }

    func testFileNameUsesSourceBaseName() {
        XCTAssertEqual(StudyProgressNote.fileName(for: URL(fileURLWithPath: "/a/교재.pdf")), "교재.md")
        XCTAssertEqual(StudyProgressNote.fileName(for: URL(fileURLWithPath: "/a/b.docx")), "b.md")
    }
}
