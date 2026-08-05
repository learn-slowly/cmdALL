import Foundation

/// 문제집 한 문항의 풀이·복습 기록. **문항 내용은 여기 없다** — 발문·보기·정답·해설은 원본
/// 문제집 md에 그대로 두고(진실의 출처 하나), 이 기록만 앱이 따로 남긴다.
/// 교재 진도 노트(`StudyOutlineChapter`)와 같은 어법이다.
struct QuizRecord: Equatable {
    /// 원본 문제집 안의 문항 번호(1-based). 이것이 원본과 이어주는 유일한 열쇠다.
    let n: Int
    var state: StudyReviewState
    /// 앵커 줄에 있던 알 수 없는 키를 그대로 보존한다(사용자·후속 버전이 더한 값을 잃지 않게).
    var extraTokens: [String] = []
}
