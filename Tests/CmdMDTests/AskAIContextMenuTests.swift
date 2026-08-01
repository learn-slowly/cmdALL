import XCTest
import AppKit
import PDFKit
import WebKit
@testable import CmdMD

/// 마우스로 블록 설정 후 오른쪽 버튼으로도 AI 호출(2026-08-01) — `menu(for:)`를 오버라이드해
/// 기본 컨텍스트 메뉴에 "Claude에게 물어보기"를 더하는 세 표면(`CmdMDTextView`·`CmdMDPDFView`·
/// `DropThroughWebView`)이 선택 유무·클로저 유무에 따라 정확히 항목을 넣고 빼는지 확인한다.
/// 실제 우클릭 이벤트·메뉴 표시는 자동 테스트 원리상 재현 불가 — 여기선 `menu(for:)`가
/// 반환하는 값만 헤드리스로 검증한다(기존 `responderYieldsFileKeys` 헤드리스 전례와 같은 패턴).
final class AskAIContextMenuTests: XCTestCase {

    private let title = "Claude에게 물어보기"

    private func syntheticRightClick() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - CmdMDTextView(마크다운 편집기)

    func testTextViewMenuIncludesAskAIWhenSelectionAndClosurePresent() {
        let textView = CmdMDTextView()
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        var called = false
        textView.onAskAI = { called = true }

        let menu = textView.menu(for: syntheticRightClick())

        let item = menu?.items.first { $0.title == title }
        XCTAssertNotNil(item, "선택 있고 onAskAI 있으면 메뉴에 떠야 한다")
        if let action = item?.action { item?.target?.perform(action, with: nil) }
        XCTAssertTrue(called)
    }

    func testTextViewMenuExcludesAskAIWhenNoSelection() {
        let textView = CmdMDTextView()
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.onAskAI = { }

        let menu = textView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title }, "선택이 없으면 메뉴에 뜨면 안 된다")
    }

    func testTextViewMenuExcludesAskAIWhenClosureNotWired() {
        let textView = CmdMDTextView()
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        // onAskAI 미설정(nil).

        let menu = textView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title }, "onAskAI가 없으면 배선 안 된 화면이라 메뉴에도 없어야 한다")
    }

    // MARK: - CmdMDPDFView(PDF 화면)

    func testPDFViewMenuExcludesAskAIWhenNoSelection() {
        let pdfView = CmdMDPDFView()
        pdfView.onAskAI = { }
        // currentSelection이 nil인 기본 상태.

        let menu = pdfView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title }, "PDF 선택이 없으면 메뉴에 뜨면 안 된다")
    }

    func testPDFViewMenuExcludesAskAIWhenClosureNotWired() {
        let pdfView = CmdMDPDFView()
        // onAskAI 미설정.

        let menu = pdfView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title })
    }

    // MARK: - DropThroughWebView(미리보기·오피스 렌더 화면)

    func testWebViewMenuIncludesAskAIWhenSelectionFlagAndClosurePresent() {
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.hasSelection = true
        var called = false
        webView.onAskAI = { called = true }

        let menu = webView.menu(for: syntheticRightClick())

        let item = menu?.items.first { $0.title == title }
        XCTAssertNotNil(item, "hasSelection true + onAskAI 있으면 메뉴에 떠야 한다")
        if let action = item?.action { item?.target?.perform(action, with: nil) }
        XCTAssertTrue(called)
    }

    func testWebViewMenuExcludesAskAIWhenNoSelectionFlag() {
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.hasSelection = false
        webView.onAskAI = { }

        let menu = webView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title })
    }

    func testWebViewMenuExcludesAskAIWhenClosureNotWired() {
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.hasSelection = true
        // onAskAI 미설정.

        let menu = webView.menu(for: syntheticRightClick())

        XCTAssertNil(menu?.items.first { $0.title == title })
    }

    // MARK: - PreviewView.Coordinator.recordSelectionChange (선택 상태 반영 순수 로직)

    func testRecordSelectionChangeUpdatesLastKnownSelectionAndForwardsText() {
        let coordinator = MarkdownPreviewView.Coordinator()
        var forwarded: String?
        coordinator.onSelectedTextChange = { forwarded = $0 }

        coordinator.recordSelectionChange("선택된 글자")

        XCTAssertEqual(coordinator.lastKnownSelection, "선택된 글자")
        XCTAssertEqual(forwarded, "선택된 글자")
    }

    func testRecordSelectionChangeWithEmptyTextClearsState() {
        let coordinator = MarkdownPreviewView.Coordinator()
        coordinator.recordSelectionChange("먼저 선택")
        XCTAssertEqual(coordinator.lastKnownSelection, "먼저 선택")

        coordinator.recordSelectionChange("")

        XCTAssertEqual(coordinator.lastKnownSelection, "")
    }

    func testRecordSelectionChangeUpdatesAttachedWebViewHasSelectionFlag() {
        let coordinator = MarkdownPreviewView.Coordinator()
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.webView = webView

        coordinator.recordSelectionChange("본문 일부")
        XCTAssertTrue(webView.hasSelection)

        coordinator.recordSelectionChange("   ") // 공백만 있으면 선택 없음과 동일 취급.
        XCTAssertFalse(webView.hasSelection)
    }
}
