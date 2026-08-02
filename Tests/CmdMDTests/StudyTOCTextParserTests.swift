import XCTest
@testable import CmdMD

/// 목차 페이지 글자 파싱(`StudyTOCTextParser`).
/// 아래 `realTextbookTOCPage`는 **실제 교재에서 그대로 뽑아온 글자**다(미디어교육사 교재
/// 개정판 2025년, PDF 4~5쪽 — 2026-08-02 실측). 설계 §목차 추출 실측 결과 참고.
final class StudyTOCTextParserTests: XCTestCase {

    /// 실제 교재 4쪽(제1과목 목차) 원문.
    private let realTOCPage4 = """
    1. 미디어의 이해
    1.1. 미디어 개념과 기능 그리고 산업구조
    1.1.1. 미디어 개념과 특징 ∙ 008
    1.1.2. 미디어 산업의 구조와 특성(영향력) ∙ 033
    1.1.3. 미디어의 기능과 영향 ∙ 055
    1.2. 미디어와 뉴스 콘텐츠
    1.2.1. 저널리즘과 뉴스 생태계에 대한 이해 ∙ 074
    1.2.2. 뉴스의 이용과 문화 ∙ 109
    1.3. 미디어와 엔터테인먼트 콘텐츠
    1.3.1. 엔터테인먼트 콘텐츠와 생태계에 대한 이해 ∙ 142
    1.3.2. 엔터테인먼트 콘텐츠 이용과 문화 ∙ 174
    """

    /// 실제 교재 5쪽 일부 — **줄바꿈된 제목**(3.3.1)이 들어 있는 구간.
    private let realTOCPage5Tail = """
    3.3. 미디어 리터러시 교육 사례 분석
    3.3.1. 미디어 리터러시 교육을 위한
    수업 전문성과 교육자 전문성 ∙ 500
    3.3.2. 미디어 리터러시 교육과 국가 교육과정 ∙ 518
    3.3.3. 미디어 리터러시 교육 사례 분석 ∙ 534
    """

    /// 실제 교재 3쪽(목차가 아닌 안내문) — 목차로 오인하면 안 되는 장.
    private let realNonTOCPage = """
    가 목적
    ∙ 본 교재는 미디어교육 분야의 전문 인력 양성을 위한 학습 자료로, 미디어
    교육사 자격시험 응시자의 학습을 지원하고 참고할 수 있는 콘텐츠를 제공
    하는 데에 그 목적이 있습니다.
    나 구성
    ∙ 본 교재는 과목별로 구성되어 있습니다.
    1. 제1과목: 미디어의 이해
    2. 제2과목: 미디어 리터러시 교육의 이해
    3. 제3과목: 미디어 교육방법 및 사례
    """

    // MARK: - 실제 교재 글자

    func testRealTextbookTOCPageYieldsLeafEntriesOnly() {
        let entries = StudyTOCTextParser.entries(fromPageText: realTOCPage4)

        XCTAssertEqual(entries.map(\.printedPage), [8, 33, 55, 74, 109, 142, 174],
                       "쪽번호가 붙은 항목만 장이 된다 — 상위 제목(1.1. 등)은 세지 않는다")
        XCTAssertEqual(entries.first?.title, "1.1.1. 미디어 개념과 특징")
        XCTAssertEqual(entries[1].title, "1.1.2. 미디어 산업의 구조와 특성(영향력)",
                       "제목 안 괄호는 그대로 살린다")
    }

    func testWrappedTitleIsJoinedWithPreviousLine() {
        let entries = StudyTOCTextParser.entries(fromPageText: realTOCPage5Tail)

        XCTAssertEqual(entries.map(\.printedPage), [500, 518, 534])
        XCTAssertEqual(entries[0].title, "3.3.1. 미디어 리터러시 교육을 위한 수업 전문성과 교육자 전문성",
                       "줄바꿈된 제목은 앞줄을 이어 붙인다")
    }

    func testNonTOCPageIsRejected() {
        let entries = StudyTOCTextParser.entries(fromPageText: realNonTOCPage)
        XCTAssertLessThan(entries.count, StudyTOCTextParser.minimumTOCLines,
                          "안내문 장은 목차 판정 기준(4줄)에 못 미쳐야 한다")
    }

    func testEntriesAcrossPagesSkipsNonTOCPages() {
        let entries = StudyTOCTextParser.entries(
            fromPageTexts: ["", "", realNonTOCPage, realTOCPage4, realTOCPage5Tail])

        XCTAssertEqual(entries.map(\.printedPage), [8, 33, 55, 74, 109, 142, 174, 500, 518, 534])
    }

    // MARK: - 줄 하나 파싱 규칙

    func testSplitTrailingPageNumberVariants() {
        XCTAssertEqual(StudyTOCTextParser.splitTrailingPageNumber("1장 총론 ∙ 008")?.page, 8)
        XCTAssertEqual(StudyTOCTextParser.splitTrailingPageNumber("1장 총론 ..... 12")?.page, 12)
        XCTAssertEqual(StudyTOCTextParser.splitTrailingPageNumber("1장 총론    45")?.title, "1장 총론")
        XCTAssertEqual(StudyTOCTextParser.splitTrailingPageNumber("서론 … 3")?.title, "서론")
    }

    func testSplitRejectsLinesWithoutSeparatorOrTitle() {
        XCTAssertNil(StudyTOCTextParser.splitTrailingPageNumber("제9장"),
                     "번호가 제목에 붙어 있으면 쪽번호가 아니다")
        XCTAssertNil(StudyTOCTextParser.splitTrailingPageNumber("2025"), "숫자만 있는 줄은 제외")
        XCTAssertNil(StudyTOCTextParser.splitTrailingPageNumber("∙ 123"), "제목 없는 줄은 제외")
        XCTAssertNil(StudyTOCTextParser.splitTrailingPageNumber("본문 마지막 문장이다"), "번호 없는 줄")
        XCTAssertNil(StudyTOCTextParser.splitTrailingPageNumber("표 12345 ∙ 12345"),
                     "5자리 이상은 쪽번호로 보지 않는다")
    }

    func testStartsWithOutlineNumber() {
        XCTAssertTrue(StudyTOCTextParser.startsWithOutlineNumber("1.1.1. 제목"))
        XCTAssertTrue(StudyTOCTextParser.startsWithOutlineNumber("12. 제목"))
        XCTAssertFalse(StudyTOCTextParser.startsWithOutlineNumber("제1장 제목"))
        XCTAssertFalse(StudyTOCTextParser.startsWithOutlineNumber("수업 전문성과 교육자 전문성"))
    }

    // MARK: - 표·그림 목록 배제(실측: 스캔 논문에서 실제로 표 목차가 잡혔다)

    func testFigureAndTableEntriesAreRejected() {
        XCTAssertTrue(StudyTOCTextParser.isFigureOrTableEntry("<표 1-1> 노동계급 행위양식의 유형"))
        XCTAssertTrue(StudyTOCTextParser.isFigureOrTableEntry("[그림 3] 조직도"))
        XCTAssertTrue(StudyTOCTextParser.isFigureOrTableEntry("Table 2 Summary"))
        XCTAssertFalse(StudyTOCTextParser.isFigureOrTableEntry("표현의 자유와 미디어"),
                       "'표'로 시작해도 바로 뒤가 번호가 아니면 멀쩡한 제목이다")
        XCTAssertFalse(StudyTOCTextParser.isFigureOrTableEntry("그림자 노동의 이해"))
    }

    func testTableListPageProducesNoEntries() {
        let tableList = """
        <표 1-1> 노동계급 행위양식의 유형 ∙ 21
        <표 1-2> 분석의 주요 대상 ∙ 25
        <표 2-1> 울산지역 공장수와 종업원수 ∙ 57
        <표 2-2> 울산지역 공업의 업종별 구성비 ∙ 60
        """
        XCTAssertTrue(StudyTOCTextParser.entries(fromPageText: tableList).isEmpty)
    }

    func testOverlongMergedTitleFallsBackToTailLine() {
        let page = """
        1.1. \(String(repeating: "아주 긴 앞줄 ", count: 12))
        실제 항목 제목 ∙ 42
        """
        let entries = StudyTOCTextParser.entries(fromPageText: page)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "실제 항목 제목",
                       "이어 붙였을 때 너무 길면 앞줄은 다른 항목이었다는 뜻이라 뒷줄만 쓴다")
    }
}
