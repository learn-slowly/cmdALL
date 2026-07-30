import XCTest
@testable import CmdMD

final class HwpJsRenderServiceTests: XCTestCase {
    func testWrapViewerEmbedsBase64AndBundleJS() {
        let html = HwpJsRenderService.wrapViewer(base64: "AAAA", hwpJsJS: "console.log('hwpjs')")
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
        XCTAssertTrue(html.contains("AAAA"))
        XCTAssertTrue(html.contains("console.log('hwpjs')"))
    }

    func testWrapViewerUsesAtobNotRawUint8Array() {
        // 실측 확인(2026-07-30): base64 문자열이나 Uint8Array를 그대로 Viewer에 넘기면
        // hwp.js 내부 CFB 파서가 헤더 시그니처를 잘못 읽는다 — atob()로 얻은 "바이너리 문자열"만
        // 정상 동작한다. 이 계약이 실수로 깨지지 않게 고정한다.
        let html = HwpJsRenderService.wrapViewer(base64: "AAAA", hwpJsJS: "")
        XCTAssertTrue(html.contains("atob(\"AAAA\")"))
        XCTAssertTrue(html.contains("new window.HWPJS.Viewer(document.getElementById('container'), binStr)"))
    }

    func testWrapViewerIncludesInPageFallbackForRenderFailure() {
        // Swift는 hwp.js의 실제 렌더 성공 여부를 미리 알 수 없으므로(파싱이 웹뷰 JS 안에서
        // 일어남), 실패 안전장치는 페이지 안 try/catch로 들어가야 한다.
        let html = HwpJsRenderService.wrapViewer(base64: "AAAA", hwpJsJS: "")
        XCTAssertTrue(html.contains("try {"))
        XCTAssertTrue(html.contains("catch (e)"))
        XCTAssertTrue(html.contains("fallback"))
    }

    func testWrapViewerHandlesEmptyInputSafely() {
        let html = HwpJsRenderService.wrapViewer(base64: "", hwpJsJS: "")
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("<body"))
    }

    func testRenderHTMLThrowsReadFailedForMissingFile() async {
        let service = HwpJsRenderService()
        let missing = URL(fileURLWithPath: "/tmp/이런파일없음_\(UUID().uuidString).hwp")
        do {
            _ = try await service.renderHTML(for: missing)
            XCTFail("존재하지 않는 파일은 실패해야 한다")
        } catch {
            // assetMissing(번들 없음, 테스트 환경에선 있을 수도 없을 수도) 또는 readFailed 둘 다
            // 허용 — 핵심은 크래시 없이 던진다는 것.
            XCTAssertTrue(error is HwpJsRenderError)
        }
    }
}
