import Foundation

/// 복습 채점 "되돌리기"(다듬기 A, 2026-08-02) — 방금 채점한 **직전 1건**만 기억한다.
/// 노트 파일을 되돌려 쓸 때 필요한 최소 정보만 담고, 메모리에만 산다(앱을 닫으면 사라짐).
struct StudyReviewUndo: Equatable {
    /// 되돌릴 항목의 고유 id(앵커 줄 식별자).
    let itemUID: UUID
    /// 그 항목이 있던 대기열 위치 — 되돌리면 화면도 이 항목으로 돌아간다.
    let queueIndex: Int
    /// 채점 **전** 복습 상태(이걸로 되돌려 쓴다).
    let previousState: StudyReviewState
    /// 채점 **전** 앵커 줄 원문 — 되돌려 쓴 뒤 캐시·대기열에 다시 넣는다.
    let previousLineText: String
    /// 채점 **후** 앵커 줄 원문 — 되돌려 쓰기 직전 재확인용(그 사이 외부에서 바뀌었으면 포기).
    let gradedLineText: String
}
