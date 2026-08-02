import XCTest
import PDFKit
@testable import CmdMD

/// 목차 추출(`StudyOutlineExtractor`) — 진도 관리의 분모를 정하는 부품.
/// 설계 `docs/superpowers/specs/2026-08-02-study-progress-design.md` §목차 추출.
final class StudyOutlineExtractorTests: XCTestCase {

    // MARK: - 공통 조립(깨진 목차 방어)

    func testChaptersFillsEndFromNextStart() {
        let chapters = StudyOutlineExtractor.chapters(
            from: [("1장", 1), ("2장", 45), ("3장", 121)], total: 200)

        XCTAssertEqual(chapters.map(\.no), [1, 2, 3])
        XCTAssertEqual(chapters.map(\.start), [1, 45, 121])
        XCTAssertEqual(chapters.map(\.end), [44, 120, 200], "각 장의 끝은 다음 장 시작 −1, 마지막은 총 분량")
        XCTAssertEqual(chapters.map(\.length), [44, 76, 80])
        XCTAssertEqual(chapters.map(\.length).reduce(0, +), 200, "장 분량의 합은 총 분량과 같아야 한다")
    }

    func testChaptersInsertsPrefaceWhenFirstStartIsNotOne() {
        let chapters = StudyOutlineExtractor.chapters(from: [("1장", 10)], total: 100)

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, StudyOutlineExtractor.prefaceTitle)
        XCTAssertEqual(chapters[0].start, 1)
        XCTAssertEqual(chapters[0].end, 9)
        XCTAssertEqual(chapters[1].start, 10)
        XCTAssertEqual(chapters.map(\.length).reduce(0, +), 100)
    }

    func testChaptersDropsNonAdvancingAndOutOfRangeEntries() {
        // 역행(30 → 20)·중복(30)·범위 밖(0, 500)은 버린다.
        let chapters = StudyOutlineExtractor.chapters(
            from: [("머리", 0), ("1장", 30), ("되돌이", 20), ("중복", 30), ("2장", 60), ("범위밖", 500)],
            total: 100)

        XCTAssertEqual(chapters.map(\.title), [StudyOutlineExtractor.prefaceTitle, "1장", "2장"])
        XCTAssertEqual(chapters.map(\.start), [1, 30, 60])
        XCTAssertEqual(chapters.map(\.end), [29, 59, 100])
    }

    func testChaptersFallsBackToSingleWholeChapter() {
        let chapters = StudyOutlineExtractor.chapters(from: [], total: 500)

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, StudyOutlineExtractor.wholeChapterTitle)
        XCTAssertEqual(chapters[0].start, 1)
        XCTAssertEqual(chapters[0].end, 500)
    }

    func testChaptersWithZeroTotalIsEmpty() {
        XCTAssertTrue(StudyOutlineExtractor.chapters(from: [("1장", 1)], total: 0).isEmpty)
    }

    func testEmptyTitleBecomesPlaceholder() {
        let chapters = StudyOutlineExtractor.chapters(from: [("   ", 1)], total: 10)
        XCTAssertEqual(chapters[0].title, "제목 없음")
    }

    // MARK: - PDF

    func testPDFWithoutOutlineOrTOCTextFallsBackToWholeDocument() throws {
        let doc = try makePDF(pageCount: 12)
        let result = StudyOutlineExtractor.fromPDF(document: doc)

        XCTAssertEqual(result.source, .fallback)
        XCTAssertEqual(result.outline.unit, .page)
        XCTAssertEqual(result.outline.total, 12)
        XCTAssertEqual(result.outline.chapters.count, 1, "목차 없는 스캔본은 '전체' 한 장으로 폴백")
        XCTAssertEqual(result.outline.chapters[0].end, 12)
    }

    func testPDFOutlineBecomesChapters() throws {
        let doc = try makePDF(pageCount: 20)
        let root = PDFOutline()
        root.insertChild(outlineItem(label: "1장 총론", page: doc.page(at: 0)!), at: 0)
        root.insertChild(outlineItem(label: "2장 계약", page: doc.page(at: 4)!), at: 1)
        root.insertChild(outlineItem(label: "3장 소송", page: doc.page(at: 11)!), at: 2)
        doc.outlineRoot = root

        let result = StudyOutlineExtractor.fromPDF(document: doc)

        XCTAssertEqual(result.source, .embedded)
        XCTAssertEqual(result.outline.chapters.map(\.title), ["1장 총론", "2장 계약", "3장 소송"])
        XCTAssertEqual(result.outline.chapters.map(\.start), [1, 5, 12])
        XCTAssertEqual(result.outline.chapters.map(\.end), [4, 11, 20])
    }

    func testPDFOutlineItemWithoutDestinationIsSkipped() throws {
        let doc = try makePDF(pageCount: 10)
        let root = PDFOutline()
        let orphan = PDFOutline()
        orphan.label = "목적지 없는 항목"
        root.insertChild(orphan, at: 0)
        root.insertChild(outlineItem(label: "2장", page: doc.page(at: 5)!), at: 1)
        doc.outlineRoot = root

        let result = StudyOutlineExtractor.fromPDF(document: doc)

        XCTAssertEqual(result.outline.chapters.map(\.title), [StudyOutlineExtractor.prefaceTitle, "2장"])
        XCTAssertEqual(result.outline.chapters.map(\.start), [1, 6])
    }

    // MARK: - 글자 목차 + 쪽번호 보정(한국 교재의 주 경로)

    func testTOCEntriesShiftedByOffset() {
        let entries = [
            StudyTOCTextParser.Entry(title: "1장", printedPage: 8),
            StudyTOCTextParser.Entry(title: "2장", printedPage: 33),
        ]
        let outline = StudyOutlineExtractor.outline(fromTOCEntries: entries, offset: -1, pageCount: 100)

        XCTAssertEqual(outline.chapters.map(\.start), [1, 7, 32],
                       "보정 −1이면 인쇄 8쪽은 PDF 7장 — 그 앞 6장은 머리말 장이 된다")
        XCTAssertEqual(outline.chapters.map(\.title), [StudyOutlineExtractor.prefaceTitle, "1장", "2장"])
    }

    func testSearchNeedleStripsNumberingAndParenthesis() {
        XCTAssertEqual(StudyOutlineExtractor.searchNeedle(from: "1.1.2. 미디어 산업의 구조와 특성(영향력)"),
                       "미디어 산업의 구조와 특성")
        XCTAssertEqual(StudyOutlineExtractor.searchNeedle(from: "제1장 총론"), "제1장 총론")
    }

    func testSpreadSampleCoversWholeList() {
        let sample = StudyOutlineExtractor.spreadSample(Array(1...100), count: 5)
        XCTAssertEqual(sample.count, 5)
        XCTAssertEqual(sample.first, 1)
        XCTAssertGreaterThan(try XCTUnwrap(sample.last), 60, "뒤쪽에서도 뽑아야 표지 근처에 치우치지 않는다")
    }

    func testSpreadSampleReturnsAllWhenShorterThanCount() {
        XCTAssertEqual(StudyOutlineExtractor.spreadSample([1, 2, 3], count: 6), [1, 2, 3])
    }

    // MARK: - 마크다운

    func testMarkdownHeadingsBecomeChaptersWithRealLineNumbers() {
        let content = """
        머리말 문장
        # 1장
        내용
        내용
        # 2장
        내용
        """
        let outline = StudyOutlineExtractor.fromMarkdown(content: content)

        XCTAssertEqual(outline.unit, .line)
        XCTAssertEqual(outline.total, 6)
        XCTAssertEqual(outline.chapters.map(\.title), [StudyOutlineExtractor.prefaceTitle, "1장", "2장"])
        XCTAssertEqual(outline.chapters.map(\.start), [1, 2, 5])
        XCTAssertEqual(outline.chapters.map(\.end), [1, 4, 6])
    }

    func testMarkdownWithoutHeadingsFallsBackToWholeFile() {
        let outline = StudyOutlineExtractor.fromMarkdown(content: "한 줄\n두 줄\n세 줄")

        XCTAssertEqual(outline.chapters.count, 1)
        XCTAssertEqual(outline.chapters[0].title, StudyOutlineExtractor.wholeChapterTitle)
        XCTAssertEqual(outline.chapters[0].end, 3)
    }

    // MARK: - 오피스

    func testOfficeSectionsBecomeOneChapterEach() {
        let body = """
        머리말 본문
        # 첫째 구간
        내용
        # 둘째 구간
        내용
        """
        let outline = StudyOutlineExtractor.fromOfficeBody(body)

        XCTAssertEqual(outline.unit, .section)
        XCTAssertEqual(outline.total, 3)
        XCTAssertEqual(outline.chapters.map(\.start), [1, 2, 3])
        XCTAssertEqual(outline.chapters.map(\.end), [1, 2, 3], "구간은 하나가 곧 한 장")
        XCTAssertEqual(outline.chapters.map(\.length), [1, 1, 1])
    }

    func testOfficeEmptyBodyGivesEmptyOutline() {
        XCTAssertTrue(StudyOutlineExtractor.fromOfficeBody("   ").isEmpty)
    }

    // MARK: - 도우미

    private func makePDF(pageCount: Int) throws -> PDFDocument {
        let doc = PDFDocument()
        for index in 0..<pageCount {
            let page = PDFPage(image: solidImage(text: "\(index + 1)"))
            doc.insert(try XCTUnwrap(page), at: index)
        }
        return doc
    }

    private func solidImage(text: String) -> NSImage {
        let size = NSSize(width: 200, height: 280)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 10, y: 10), withAttributes: nil)
        image.unlockFocus()
        return image
    }

    private func outlineItem(label: String, page: PDFPage) -> PDFOutline {
        let item = PDFOutline()
        item.label = label
        item.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: 0))
        return item
    }
}
