import XCTest
@testable import CmdMD

final class KordocRenderServiceTests: XCTestCase {
    func testWrapSVGPreservesSVGContentAndWrapsInHTML() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><text>안녕</text></svg>"
        let html = KordocRenderService.wrapSVG(svg)
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
        XCTAssertTrue(html.contains(svg))
    }

    func testWrapSVGHandlesEmptyInputSafely() {
        let html = KordocRenderService.wrapSVG("")
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
    }

    func testWrapSVGHandlesNonSVGInputSafely() {
        // svg 태그가 없는 입력(방어 케이스)도 파싱·검증 없이 그대로 실어 반환한다 — 크래시 없음.
        let text = "이건 svg가 아닌 그냥 텍스트입니다."
        let html = KordocRenderService.wrapSVG(text)
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains(text))
    }
}
