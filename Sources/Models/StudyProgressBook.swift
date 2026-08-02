import Foundation

/// 진도 화면의 교재 한 권 — 진도 노트 파일 하나에서 읽어낸 것 + 그 교재로 만든 카드·문제로
/// 계산한 진도. 화면(`StudyProgressView`)이 그대로 그리면 되는 모양이다.
struct StudyProgressBook: Identifiable, Equatable {
    /// 진도 노트의 `study_progress_id`.
    let id: UUID
    /// 진도 노트 파일 경로.
    let noteURL: URL
    /// 교재 파일 절대경로(상대경로를 푼 값). 못 풀면 nil.
    let sourceURL: URL?
    let sourceKind: DocumentKind?
    /// 교재가 지금도 그 자리에 있는지 — 옮기거나 지웠으면 화면이 알려준다.
    let sourceExists: Bool
    let pageOffset: Int
    let summary: StudyProgressSummary

    /// 화면에 쓰는 이름 — 교재 파일 이름(없으면 진도 노트 이름).
    var title: String {
        sourceURL?.lastPathComponent ?? noteURL.deletingPathExtension().lastPathComponent
    }
}
