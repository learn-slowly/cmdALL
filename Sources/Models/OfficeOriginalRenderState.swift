import Foundation

/// 오피스 "원본 보기"(kordoc render SVG — hwpx / hwp.js — hwp) 상태.
/// `AppState.officeOriginalRenderStates`(키=EditorTab.id)에 담긴다.
/// 기존 `OfficeState`(변환 상태)와 모양은 같지만 별개 딕셔너리 — 오피스 변환과 원본 렌더는
/// 독립적으로 로딩·실패할 수 있어 섞지 않는다. 엔진(kordoc render / hwp.js)이 갈려도
/// 결과는 둘 다 "WKWebView에 바로 로드할 HTML 문자열"이라 상태·화면을 공유한다.
enum OfficeOriginalRenderState {
    case loading
    case loaded(html: String)
    case failed(String)
}
