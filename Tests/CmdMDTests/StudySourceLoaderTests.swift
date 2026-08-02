import XCTest
import PDFKit
import AppKit
import CoreText
@testable import CmdMD

/// S1 두 번째 조각 — `StudySourceLoader`가 종류별로 위치 태그(§5.1~5.2)를 맞게 붙이는지
/// 확인한다. office는 kordoc 변환(외부 프로세스) 자체는 기존 관행대로(`ContentExtractorTests`
/// 전례) 단위 테스트하지 않지만, **변환된 글을 구간으로 나누는 로직**(`officeSegments`,
/// §5.2 I3)은 순수 함수라 kordoc 없이 직접 검증한다.
final class StudySourceLoaderTests: XCTestCase {

    // MARK: - 마크다운/텍스트: 헤딩 경계 → 줄 번호

    func testTextSegmentsSplitAtHeadingBoundariesUsingHeadingLineAsLocator() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let content = "머리말 문단\n\n# 첫 장\n첫 장 본문\n\n# 둘째 장\n둘째 장 본문\n"
        let url = dir.appendingPathComponent("note.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .markdown, range: .wholeFile))

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].locator, .line(1))
        XCTAssertTrue(segments[0].text.contains("머리말"))
        XCTAssertEqual(segments[1].locator, .line(3))
        XCTAssertTrue(segments[1].text.contains("첫 장 본문"))
        XCTAssertEqual(segments[2].locator, .line(6))
        XCTAssertTrue(segments[2].text.contains("둘째 장 본문"))
    }

    func testTextSegmentsWithNoHeadingsProduceOneSegmentStartingAtRangeLine() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let content = "그냥 평문 첫 줄\n둘째 줄\n셋째 줄\n"
        let url = dir.appendingPathComponent("plain.txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .markdown, range: .wholeFile))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].locator, .line(1))
        XCTAssertEqual(segments[0].text, "그냥 평문 첫 줄\n둘째 줄\n셋째 줄")
    }

    func testTextSegmentsLineRangeStartsFromRangeLineNotPrecedingHeading() async throws {
        // 헤딩(1줄)이 선택 범위(3~4줄) 밖에 있으면 그 헤딩은 시작점이 아니고, 조각은
        // 범위의 첫 줄(3)에서 시작해야 한다.
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let content = "# 장 제목\n장 도입부\n선택된 셋째 줄\n선택된 넷째 줄\n선택 안 된 다섯째 줄\n"
        let url = dir.appendingPathComponent("range.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(
            for: StudyScope(fileURL: url, kind: .markdown, range: .lineRange(3, 4))
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].locator, .line(3))
        XCTAssertEqual(segments[0].text, "선택된 셋째 줄\n선택된 넷째 줄")
    }

    func testTextSegmentsReturnsEmptyForBlankFile() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = dir.appendingPathComponent("blank.md")
        try "   \n\n  \n".write(to: url, atomically: true, encoding: .utf8)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .markdown, range: .wholeFile))

        XCTAssertTrue(segments.isEmpty)
    }

    func testTextSegmentsReturnsEmptyForInvertedLineRange() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = dir.appendingPathComponent("short.md")
        try "한 줄짜리".write(to: url, atomically: true, encoding: .utf8)
        let loader = StudySourceLoader(kordoc: KordocService())

        // 파일이 1줄뿐인데 5~9줄을 요청 — 범위가 파일 밖.
        let segments = await loader.segments(
            for: StudyScope(fileURL: url, kind: .markdown, range: .lineRange(5, 9))
        )

        XCTAssertTrue(segments.isEmpty)
    }

    func testTextSegmentsReturnsEmptyForMissingFile() async throws {
        let missing = URL(fileURLWithPath: "/tmp/cmdall-없는-노트-\(UUID().uuidString).md")
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: missing, kind: .markdown, range: .wholeFile))

        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - 오피스: 제목(헤딩) 구간 부분 선택(§5.2 I3) — kordoc 없이 순수 함수만 검증

    func testOfficeSegmentsSplitAtHeadingBoundariesWithSectionLocators() {
        let body = "머리말\n\n# 1장\n1장 본문\n\n# 2장\n2장 본문\n"

        let segments = StudySourceLoader.officeSegments(body: body, range: .wholeFile)

        XCTAssertEqual(segments.count, 3)
        // 2026-08-02: 원본 쪽수는 몰라도 "몇 번째 구간"은 남긴다(진도의 만듦·익힘 연결).
        XCTAssertEqual(segments.map(\.locator), [.section(1), .section(2), .section(3)])
        XCTAssertTrue(segments[0].text.contains("머리말"))
        XCTAssertTrue(segments[1].text.contains("1장 본문"))
        XCTAssertTrue(segments[2].text.contains("2장 본문"))
    }

    func testOfficeSegmentsWithNoHeadingsProduceOneWholeSection() {
        let body = "표만 있는 문서\n| a | b |\n|---|---|\n| 1 | 2 |\n"

        let segments = StudySourceLoader.officeSegments(body: body, range: .wholeFile)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].locator, .section(1))
        XCTAssertTrue(segments[0].text.contains("표만 있는 문서"))
    }

    func testOfficeSegmentsSectionRangeSelectsOnlyChosenSection() {
        let body = "# 1장\n1장 내용\n\n# 2장\n2장 내용\n\n# 3장\n3장 내용\n"

        let segments = StudySourceLoader.officeSegments(body: body, range: .sectionRange(2, 2))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].locator, .section(2), "고른 구간의 실제 번호가 붙어야 한다")
        XCTAssertTrue(segments[0].text.contains("2장 내용"))
        XCTAssertFalse(segments[0].text.contains("1장 내용"))
        XCTAssertFalse(segments[0].text.contains("3장 내용"))
    }

    func testOfficeSegmentsSectionRangeClampsToSectionCount() {
        let body = "# 1장\n내용1\n\n# 2장\n내용2\n\n# 3장\n내용3\n"

        // 2~10구간을 요청했지만 구간은 3개뿐 — 3구간까지만.
        let segments = StudySourceLoader.officeSegments(body: body, range: .sectionRange(2, 10))

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].text.contains("내용2"))
        XCTAssertTrue(segments[1].text.contains("내용3"))
    }

    func testOfficeSegmentsReturnsEmptyWhenSectionRangeStartsAfterSectionCount() {
        let body = "# 1장\n내용1\n\n# 2장\n내용2\n"

        let segments = StudySourceLoader.officeSegments(body: body, range: .sectionRange(5, 10))

        XCTAssertTrue(segments.isEmpty)
    }

    func testOfficeSegmentsReturnsEmptyForBlankBody() {
        let segments = StudySourceLoader.officeSegments(body: "   \n\n  \n", range: .wholeFile)

        XCTAssertTrue(segments.isEmpty)
    }

    func testOfficeSegmentsReturnsEmptyForMismatchedRangeType() {
        // 오피스는 쪽·줄 범위 개념이 없다 — 스코프가 잘못 짝지어져도 크래시 없이 빈 배열.
        let body = "# 1장\n내용\n"

        let pageRangeResult = StudySourceLoader.officeSegments(body: body, range: .pageRange(1, 2))
        let lineRangeResult = StudySourceLoader.officeSegments(body: body, range: .lineRange(1, 2))

        XCTAssertTrue(pageRangeResult.isEmpty)
        XCTAssertTrue(lineRangeResult.isEmpty)
    }

    // MARK: - 오피스 구간 선택 화면용 제목 붙이기(labeledSections) — 범위 고르는 화면의 데이터 소스

    func testLabeledSectionsAttachesHeadingTitlesInOrder() {
        let body = "# 1장 서론\n1장 내용\n\n# 2장 본론\n2장 내용\n\n# 3장 결론\n3장 내용\n"

        let labeled = StudySourceLoader.labeledSections(from: body)

        XCTAssertEqual(labeled.map(\.index), [1, 2, 3])
        XCTAssertEqual(labeled.map(\.title), ["1장 서론", "2장 본론", "3장 결론"])
    }

    func testLabeledSectionsFirstSectionWithoutHeadingUsesPreambleLabel() {
        let body = "머리말 문단\n\n# 1장\n1장 내용\n"

        let labeled = StudySourceLoader.labeledSections(from: body)

        XCTAssertEqual(labeled.map(\.index), [1, 2])
        XCTAssertEqual(labeled[0].title, "머리말")
        XCTAssertEqual(labeled[1].title, "1장")
    }

    func testLabeledSectionsNoHeadingsProducesSingleSection() {
        let body = "표만 있는 문서\n| a | b |\n|---|---|\n| 1 | 2 |\n"

        let labeled = StudySourceLoader.labeledSections(from: body)

        XCTAssertEqual(labeled.count, 1)
        XCTAssertEqual(labeled[0].index, 1)
    }

    func testLabeledSectionsSkipsEmptySectionsButKeepsIndexContiguous() {
        // 첫 헤딩 앞이 빈 줄뿐이라 그 구간(1번)이 통째로 건너뛰어진다 — 남는 구간의 index는
        // 2가 아니라 1로 다시 매겨져야 한다(officeSegments가 받는 번호와 정확히 같아야 함).
        let body = "\n\n# 1장\n1장 내용\n"

        let labeled = StudySourceLoader.labeledSections(from: body)

        XCTAssertEqual(labeled.map(\.index), [1])
        XCTAssertEqual(labeled[0].title, "1장")
    }

    func testLabeledSectionsEmptyBodyProducesNoSections() {
        XCTAssertTrue(StudySourceLoader.labeledSections(from: "   \n\n  \n").isEmpty)
    }

    /// `labeledSections`의 index가 `officeSegments`(실제 채택 로직)가 쓰는 구간 번호와
    /// 정확히 같은지 — 화면에서 고른 번호를 그대로 넘겨도 같은 구간이 나와야 한다.
    func testLabeledSectionsIndexMatchesOfficeSegmentsSectionRange() {
        let body = "머리말\n\n# 1장\n1장 내용\n\n# 2장\n2장 내용\n"
        let labeled = StudySourceLoader.labeledSections(from: body)
        XCTAssertEqual(labeled.map(\.title), ["머리말", "1장", "2장"])

        let secondSection = StudySourceLoader.officeSegments(body: body, range: .sectionRange(2, 2))
        XCTAssertEqual(secondSection.count, 1)
        XCTAssertTrue(secondSection[0].text.contains("1장 내용"))
    }

    // MARK: - PDF: 인덱스+1 · 범위 클램프 · 빈 쪽 스킵

    func testPDFSegmentsUsePageIndexPlusOneAsLocator() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = makeTextPDF(pages: ["첫 쪽 내용", "둘째 쪽 내용", "셋째 쪽 내용"], in: dir)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .pdf, range: .wholeFile))

        XCTAssertEqual(segments.map(\.locator), [.page(1), .page(2), .page(3)])
        XCTAssertTrue(segments[0].text.contains("첫 쪽"))
        XCTAssertTrue(segments[2].text.contains("셋째 쪽"))
    }

    func testPDFSegmentsClampPageRangeToDocumentBounds() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = makeTextPDF(pages: ["첫 쪽", "둘째 쪽", "셋째 쪽"], in: dir)
        let loader = StudySourceLoader(kordoc: KordocService())

        // 요청은 2~10쪽이지만 문서는 3쪽뿐 — 3쪽까지만 클램프.
        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .pdf, range: .pageRange(2, 10)))

        XCTAssertEqual(segments.map(\.locator), [.page(2), .page(3)])
    }

    func testPDFSegmentsReturnsEmptyWhenRangeStartsAfterDocumentEnds() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = makeTextPDF(pages: ["첫 쪽", "둘째 쪽", "셋째 쪽"], in: dir)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .pdf, range: .pageRange(5, 10)))

        XCTAssertTrue(segments.isEmpty)
    }

    func testPDFSegmentsSkipsPageThatIsEmptyEvenAfterOCRFallback() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        // 텍스트 레이어도 없고(비트맵 이미지 페이지) 그림 위에 글자도 없는(흰 배경) 쪽 —
        // OCR로도 아무것도 못 건지는 진짜 빈 쪽.
        let pdf = PDFDocument()
        let blank = blankImage(size: CGSize(width: 200, height: 100))
        pdf.insert(try XCTUnwrap(PDFPage(image: blank)), at: 0)
        let url = dir.appendingPathComponent("blank.pdf")
        XCTAssertTrue(pdf.write(to: url))
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .pdf, range: .wholeFile))

        XCTAssertTrue(segments.isEmpty)
    }

    func testPDFSegmentsReturnsEmptyForLineRangeScope() async throws {
        // PDF는 줄 범위 개념이 없다 — 스코프가 잘못 짝지어져도 크래시 없이 빈 배열.
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = makeTextPDF(pages: ["내용"], in: dir)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .pdf, range: .lineRange(1, 5)))

        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - 이미지: OCR 항상 시도 + 위치 불명

    func testImageSegmentsUseUnknownLocatorAndRunOCRRegardlessOfGlobalSetting() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let image = imageWithText("STUDY", size: CGSize(width: 400, height: 200))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return XCTFail("PNG 인코딩 실패") }
        let url = dir.appendingPathComponent("photo.png")
        try png.write(to: url)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .image, range: .wholeFile))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].locator, .unknown)
        XCTAssertTrue(segments[0].text.uppercased().contains("STUDY"), "OCR 결과: \(segments[0].text)")
    }

    func testImageSegmentsReturnsEmptyWhenNoTextFound() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let image = blankImage(size: CGSize(width: 200, height: 100))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return XCTFail("PNG 인코딩 실패") }
        let url = dir.appendingPathComponent("blank.png")
        try png.write(to: url)
        let loader = StudySourceLoader(kordoc: KordocService())

        let segments = await loader.segments(for: StudyScope(fileURL: url, kind: .image, range: .wholeFile))

        XCTAssertTrue(segments.isEmpty)
    }

    func testMediaAndQuickLookScopesReturnEmptySegments() async throws {
        // §5.2: media·quickLook은 로더 단계에서 제외한다(미디어→마크다운 리다이렉트는
        // 스코프를 구성하는 화면의 몫).
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let mediaURL = dir.appendingPathComponent("song.mp3")
        try Data([0x00]).write(to: mediaURL)
        let loader = StudySourceLoader(kordoc: KordocService())

        let mediaSegments = await loader.segments(for: StudyScope(fileURL: mediaURL, kind: .media, range: .wholeFile))
        let quickLookSegments = await loader.segments(
            for: StudyScope(fileURL: mediaURL, kind: .quickLook, range: .wholeFile)
        )

        XCTAssertTrue(mediaSegments.isEmpty)
        XCTAssertTrue(quickLookSegments.isEmpty)
    }

    // MARK: - 헬퍼

    private func blankImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func imageWithText(_ text: String, size: CGSize) -> NSImage {
        let image = blankImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: text).draw(at: NSPoint(x: 20, y: size.height / 2 - 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    /// 실제 글자 레이어가 있는 PDF(페이지 목록, 1쪽당 텍스트 1줄)를 만든다. `PDFPage(image:)`와
    /// 달리 `CTLineDraw`로 PDF 콘텐츠 스트림에 진짜 텍스트 객체를 그려 넣어 `page.string`이
    /// OCR 없이도 값을 돌려준다.
    private func makeTextPDF(pages: [String], in dir: URL) -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 300)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 10, y: 270)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let url = dir.appendingPathComponent("\(UUID().uuidString).pdf")
        try! (data as Data).write(to: url)
        return url
    }
}
