import XCTest
@testable import CmdMD

/// 학습 노트의 근거 태그(`> 근거: [[p9]] "…"`)를 원본 자료 위치로 잇는 순수 헬퍼 검증
/// (레고 2026-08-01 "이게 링크가 안 걸리네?" — 태그가 노트 이름으로 취급돼 아무 데도 못 가던 문제).
final class StudySourceLinkTests: XCTestCase {

    private let noteFolder = URL(fileURLWithPath: "/Users/lego/vault/study")

    private func note(src: String, loc: String, studySource: String? = nil) -> String {
        let sourceLine = studySource.map { "study_source: \"\($0)\"\n" } ?? ""
        return """
        ---
        study_id: 00000000-0000-0000-0000-000000000001
        study_kind: card
        \(sourceLine)study_items: 1
        ---

        # 노트

        <!-- study item=00000000-0000-0000-0000-000000000002 src=\(src) loc=\(loc) due=2026-08-01 ivl=0 ease=2.50 reps=0 lapses=0 -->
        ### [카드] 제목
        - 내용
        > 근거: [[\(loc == "-" ? "?" : loc)]] "발췌"
        """
    }

    // MARK: - 태그 → 위치

    func testLocatorParsesPageTag() {
        XCTAssertEqual(StudySourceLink.locator(fromTag: "p9"), .page(9))
    }

    func testLocatorParsesPageRangeTag() {
        XCTAssertEqual(StudySourceLink.locator(fromTag: "p9-12"), .pageRange(9, 12))
    }

    func testLocatorParsesLineTag() {
        XCTAssertEqual(StudySourceLink.locator(fromTag: "l345"), .line(345))
    }

    func testLocatorParsesUnknownTag() {
        XCTAssertEqual(StudySourceLink.locator(fromTag: "?"), .unknown)
    }

    func testLocatorRejectsOrdinaryNoteName() {
        XCTAssertNil(StudySourceLink.locator(fromTag: "미디어_개념"))
        XCTAssertNil(StudySourceLink.locator(fromTag: "photo"))   // p로 시작하지만 숫자가 아니다.
        XCTAssertNil(StudySourceLink.locator(fromTag: "lego"))
    }

    // MARK: - 노트 본문 → 원본 경로

    func testSourceRelativePathUsesMatchingAnchor() {
        let content = note(src: "../%EA%B5%90%EC%9E%AC.pdf", loc: "p9")
        XCTAssertEqual(StudySourceLink.sourceRelativePath(for: .page(9), in: content),
                       "../%EA%B5%90%EC%9E%AC.pdf")
    }

    func testSourceRelativePathFallsBackToFirstAnchorWhenLocatorDiffers() {
        let content = note(src: "../book.pdf", loc: "p9")
        XCTAssertEqual(StudySourceLink.sourceRelativePath(for: .page(77), in: content), "../book.pdf")
    }

    func testSourceRelativePathFallsBackToFrontmatterWhenNoAnchors() {
        let content = """
        ---
        study_id: 00000000-0000-0000-0000-000000000001
        study_kind: chat
        study_source: "../book.pdf"
        ---

        # 대화 노트
        """
        XCTAssertEqual(StudySourceLink.sourceRelativePath(for: .page(3), in: content), "../book.pdf")
    }

    func testSourceRelativePathIsNilForOrdinaryNote() {
        let content = "# 그냥 노트\n\n본문뿐이다.\n"
        XCTAssertNil(StudySourceLink.sourceRelativePath(for: .page(9), in: content))
    }

    // MARK: - 상대경로 → 절대 URL

    func testSourceURLDecodesPercentEncodingAndResolvesRelative() {
        let url = StudySourceLink.sourceURL(relativePath: "../%EA%B5%90%EC%9E%AC.pdf", noteFolder: noteFolder)
        XCTAssertEqual(url?.path, "/Users/lego/vault/교재.pdf")
    }

    func testSourceURLKeepsAbsolutePath() {
        let url = StudySourceLink.sourceURL(relativePath: "/tmp/book.pdf", noteFolder: noteFolder)
        XCTAssertEqual(url?.path, "/tmp/book.pdf")
    }

    func testSourceURLIsNilForEmptyPath() {
        XCTAssertNil(StudySourceLink.sourceURL(relativePath: "", noteFolder: noteFolder))
    }

    // MARK: - 위치 → 점프 인자

    func testPageAndLineExtraction() {
        XCTAssertEqual(StudySourceLink.page(of: .page(9)), 9)
        XCTAssertEqual(StudySourceLink.page(of: .pageRange(9, 12)), 9)
        XCTAssertNil(StudySourceLink.page(of: .line(3)))
        XCTAssertNil(StudySourceLink.page(of: .unknown))
        XCTAssertEqual(StudySourceLink.line(of: .line(345)), 345)
        XCTAssertNil(StudySourceLink.line(of: .page(9)))
    }
}
