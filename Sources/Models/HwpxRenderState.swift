import Foundation

/// hwpx "원본 보기"(kordoc render SVG) 상태. `AppState.hwpxRenderStates`(키=EditorTab.id)에 담긴다.
/// 기존 `OfficeState`(변환 상태)와 모양은 같지만 별개 딕셔너리 — 오피스 변환과 원본 렌더는
/// 독립적으로 로딩·실패할 수 있어 섞지 않는다.
enum HwpxRenderState {
    case loading
    case loaded(html: String)
    case failed(String)
}
