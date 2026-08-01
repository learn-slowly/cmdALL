import Foundation

/// 학습 노트 하나가 카드 모음인지 문제 모음인지 — frontmatter `study_kind`로 저장된다(§3.5).
/// "챕터 1개 = 노트 1개"이고 노트 안 항목은 전부 같은 kind다(Q1 근거 a).
enum StudyItemKind: String, Equatable {
    case card
    case question
}

/// 정리 카드 한 장(§O1). 불릿 1~3개(4번째부터는 파서가 폐기, §O3), 근거 정확히 1개.
struct StudyCard: Equatable {
    let title: String
    let bullets: [String]
    let locator: StudyLocator
    /// 교재 원문에서 그대로 가져온 근거 발췌.
    let quote: String
    /// `quote`가 원문 부분 문자열과 정확히 일치하지 않을 때 true — 폐기하지 않고 표시만 한다(§O4).
    let unverifiedQuote: Bool
}

/// 문제 한 문항(§O1). `type`은 파서가 그대로 담는 자유 문자열이며, "mcq"일 때만
/// 보기(`options`) 3~5개가 필수다(§O2) — 그 외 값은 보기 없이도 유효하다.
struct StudyQuestion: Equatable {
    let title: String
    let type: String
    let prompt: String
    let options: [String]
    let answer: String
    let explanation: String
    let locator: StudyLocator
    /// 교재 원문에서 그대로 가져온 근거 발췌.
    let quote: String
    /// `quote`가 원문 부분 문자열과 정확히 일치하지 않을 때 true — 폐기하지 않고 표시만 한다(§O4).
    let unverifiedQuote: Bool
}

/// 항목 하나의 복습 상태. 진실의 출처는 학습 노트 앵커 줄(§3.3)이고, 이 struct는 그 값을
/// 메모리에서 다루기 위한 그릇일 뿐이다 — 실제 갱신 계산은 `ReviewScheduler`(예정) 몫.
struct StudyReviewState: Equatable {
    var due: Date
    /// 복습 간격(일). §3.9 상한 180일.
    var interval: Int
    /// §3.9 허용 범위 [1.30, 2.80].
    var ease: Double
    var reps: Int
    var lapses: Int

    /// 한 번도 복습하지 않은 새 항목의 시작값 — SM-2 계열의 통상 기본 ease(2.5), 첫 `due`는 오늘.
    static func initial(now: Date = Date()) -> StudyReviewState {
        StudyReviewState(due: now, interval: 0, ease: 2.5, reps: 0, lapses: 0)
    }
}
