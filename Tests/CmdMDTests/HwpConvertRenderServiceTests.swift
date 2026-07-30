import XCTest
@testable import CmdMD

final class HwpConvertRenderServiceTests: XCTestCase {
    func testWrapExtractorEmbedsBase64AndBundleJS() {
        let html = HwpConvertRenderService.wrapExtractor(base64: "AAAA", hwpConvertJS: "console.log('hwpconvert')")
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
        XCTAssertTrue(html.contains("AAAA"))
        XCTAssertTrue(html.contains("console.log('hwpconvert')"))
    }

    func testWrapExtractorCallsHwpToHwpxThenExtractHtml() {
        // 계약 고정(2026-07-30 실측): HWP→HWPX 변환 후 HwpxReader.extractHtml로 서식 있는
        // HTML을 뽑는 두 단계 호출이 실수로 깨지지 않게 한다.
        let html = HwpConvertRenderService.wrapExtractor(base64: "AAAA", hwpConvertJS: "")
        XCTAssertTrue(html.contains("window.HWPCONVERT.hwpToHwpx("))
        XCTAssertTrue(html.contains("new window.HWPCONVERT.HwpxReader()"))
        XCTAssertTrue(html.contains("reader.extractHtml("))
    }

    func testWrapExtractorIncludesInPageFallbackForFailure() {
        // Swift는 hwp-convert의 실제 변환·추출 성공 여부를 미리 알 수 없으므로(웹뷰 JS 안에서
        // 일어남), 실패 안전장치는 페이지 안 try/catch로 들어가야 한다.
        let html = HwpConvertRenderService.wrapExtractor(base64: "AAAA", hwpConvertJS: "")
        XCTAssertTrue(html.contains("try {"))
        XCTAssertTrue(html.contains("catch (e)"))
        XCTAssertTrue(html.contains("fallback"))
    }

    func testWrapExtractorHandlesEmptyInputSafely() {
        let html = HwpConvertRenderService.wrapExtractor(base64: "", hwpConvertJS: "")
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
    }

    func testRenderHTMLThrowsReadFailedForMissingFile() async {
        let service = HwpConvertRenderService()
        let missing = URL(fileURLWithPath: "/tmp/이런파일없음_\(UUID().uuidString).hwp")
        do {
            _ = try await service.renderHTML(for: missing)
            XCTFail("존재하지 않는 파일은 실패해야 한다")
        } catch {
            // assetMissing(번들 없음, 테스트 환경에선 있을 수도 없을 수도) 또는 readFailed 둘 다
            // 허용 — 핵심은 크래시 없이 던진다는 것.
            XCTAssertTrue(error is HwpConvertRenderError)
        }
    }
}
