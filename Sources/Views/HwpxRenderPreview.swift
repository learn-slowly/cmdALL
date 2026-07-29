import SwiftUI
import WebKit

/// hwpx "원본 보기" — kordoc render(SVG)를 감싼 HTML을 표시한다. 상태별 화면:
/// 로딩 스피너 / 렌더된 SVG(WKWebView) / 실패(안내 + "글로 보기로 전환" 버튼).
/// 실패 화면은 기존 `OfficeReaderView`의 `case .failed`와 같은 모양·톤을 맞췄다.
struct HwpxRenderPreview: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    var body: some View {
        switch appState.hwpxRenderStates[tabID] {
        case .loaded(let html):
            HwpxSVGWebView(html: html)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("글로 보기로 전환") {
                    appState.toggleOfficeOriginalView(tabID: tabID, fileURL: fileURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .loading, .none:
            VStack(spacing: 12) {
                ProgressView()
                Text("원본 그리는 중…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// SVG를 담은 HTML을 보여주는 얇은 WKWebView 래퍼. 스크롤·트랙패드 확대면 충분해
/// `MarkdownPreviewView` 같은 스크롤 싱크·메시지 브릿지는 두지 않는다. `DropThroughWebView`를
/// 써서(기존 프리뷰와 동일 이유) 파일 드래그를 삼키지 않고 창 레벨로 흘려보낸다.
private struct HwpxSVGWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // html이 안 바뀌었으면 재로드하지 않는다 — SwiftUI가 무관한 상태 변경으로 body를
        // 다시 그릴 때마다 웹뷰를 리로드해 깜빡이는 것을 막는다(MarkdownPreviewView의
        // lastSource 비교와 같은 이유).
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML: String = ""
    }
}
