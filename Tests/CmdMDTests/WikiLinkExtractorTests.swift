import XCTest
@testable import CmdMD

/// `WikiLinkExtractor` — 3문법 추출(순수 함수, 디스크 접근 없음).
final class WikiLinkExtractorTests: XCTestCase {
    func testMarkdownLinkWithExtension() {
        let links = WikiLinkExtractor.links(in: "[제목](경로.md)")
        XCTAssertEqual(links, [WikiRawLink(kind: .markdown, rawTarget: "경로.md", displayText: "제목")])
    }

    func testMarkdownLinkWithoutExtension() {
        let links = WikiLinkExtractor.links(in: "[제목](경로)")
        XCTAssertEqual(links, [WikiRawLink(kind: .markdown, rawTarget: "경로", displayText: "제목")])
    }

    func testWikiLinkSimple() {
        let links = WikiLinkExtractor.links(in: "[[페이지]]")
        XCTAssertEqual(links, [WikiRawLink(kind: .wiki, rawTarget: "페이지", displayText: nil)])
    }

    func testWikiLinkWithAlias() {
        // MarkdownRenderer.processWikiLinks와 동일 규약 — 파이프 뒤(target=b)가 실제 내비게이션 대상.
        let links = WikiLinkExtractor.links(in: "[[a|b]]")
        XCTAssertEqual(links, [WikiRawLink(kind: .wiki, rawTarget: "b", displayText: "a")])
    }

    func testEmbed() {
        let links = WikiLinkExtractor.links(in: "![[페이지]]")
        XCTAssertEqual(links, [WikiRawLink(kind: .embed, rawTarget: "페이지", displayText: nil)])
    }

    func testMarkdownImageExcluded() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "![대체텍스트](x.png)").isEmpty)
    }

    func testHttpAndHttpsExcluded() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "[사이트](http://example.com)").isEmpty)
        XCTAssertTrue(WikiLinkExtractor.links(in: "[사이트](https://example.com)").isEmpty)
    }

    func testMailtoExcluded() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "[메일](mailto:a@b.com)").isEmpty)
    }

    func testAnchorOnlyExcluded() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "[절로](#절)").isEmpty)
    }

    func testCodeFenceExcluded() {
        let markdown = """
        본문
        ```
        [[예시]]
        [텍스트](예시.md)
        ```
        끝
        """
        XCTAssertTrue(WikiLinkExtractor.links(in: markdown).isEmpty)
    }

    func testInlineCodeExcluded() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "설명: `[[예시]]` 라고 쓰면 됩니다.").isEmpty)
    }

    func testFrontmatterExcluded() {
        let markdown = """
        ---
        title: 문서
        alias: "[[예시]]"
        ---
        # 본문
        [[진짜링크]]
        """
        let links = WikiLinkExtractor.links(in: markdown)
        XCTAssertEqual(links, [WikiRawLink(kind: .wiki, rawTarget: "진짜링크", displayText: nil)])
    }

    func testMultipleLinksOnOneLine() {
        let links = WikiLinkExtractor.links(in: "[[a]] 그리고 [[b]] 그리고 [c](d.md)")
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.map(\.rawTarget), ["a", "b", "d.md"])
    }

    func testKoreanSpaceAndPathVariants() {
        let links = WikiLinkExtractor.links(in: "[[한글 페이지 이름]]과 [경로](하위 폴더/한글 문서.md)")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0], WikiRawLink(kind: .wiki, rawTarget: "한글 페이지 이름", displayText: nil))
        XCTAssertEqual(links[1], WikiRawLink(kind: .markdown, rawTarget: "하위 폴더/한글 문서.md", displayText: "경로"))
    }

    func testEmptyStringProducesNoLinks() {
        XCTAssertTrue(WikiLinkExtractor.links(in: "").isEmpty)
    }

    func testOrderIsDocumentOrder() {
        let links = WikiLinkExtractor.links(in: "[c](3.md)\n[[1]]\n[[2]]")
        XCTAssertEqual(links.map(\.rawTarget), ["3.md", "1", "2"])
    }
}
