import Foundation

/// 문제집 목록의 한 줄 — 문제집 고르는 화면이 쓴다.
struct QuizBook: Equatable, Identifiable {
    /// 원본 문제집 md.
    let sourceURL: URL
    /// 기록장 파일. 아직 한 번도 안 푼 문제집이면 nil(풀기 시작할 때 만든다).
    let recordURL: URL?
    /// 원본에서 실제로 읽어낸 문항 수.
    let itemCount: Int
    /// 오늘 풀 몫(기록장의 `due`가 오늘까지인 문항). 기록장이 없으면 전체가 새 문항이다.
    let dueCount: Int
    /// 한 번이라도 채점한 문항 수 — 목록에서 "얼마나 풀었나"를 보여준다.
    let solvedCount: Int

    var id: URL { sourceURL }
    /// 화면에 보일 이름(파일 이름에서 확장자만 뗀 것).
    var title: String { sourceURL.deletingPathExtension().lastPathComponent }
    var isStarted: Bool { recordURL != nil }
}

/// 지금 풀고 있는 문제 한 문항 — 원본에서 읽은 내용 + 기록장의 복습 상태 + 이번 판의 정오.
struct QuizItem: Equatable, Identifiable {
    let n: Int
    let question: StudyQuestion
    var state: StudyReviewState
    /// 이번 판에서 내가 고른 보기 번호(1-based). 아직 안 골랐으면 nil.
    var picked: Int?
    /// 해설을 펼쳤는지(문항마다 따로 기억한다).
    var explanationShown: Bool = false

    var id: Int { n }
    /// 정답 번호(1-based). 파서가 `A:`를 번호로 옮겨 둔 값.
    var answer: Int { Int(question.answer) ?? 0 }
    var isSolved: Bool { picked != nil }
    var isCorrect: Bool { picked == answer }
}

/// 문제 목록을 걸러 보는 방법(mediaedu-quiz의 하단 바 + 형식 탭).
enum QuizFilter: Equatable {
    case all
    /// 아직 답을 안 고른 것.
    case unsolved
    /// 이번 판에서 틀린 것.
    case wrong
    /// 형식별(`A. 옳은 것 고르기` 등).
    case type(String)

    func matches(_ item: QuizItem) -> Bool {
        switch self {
        case .all: return true
        case .unsolved: return !item.isSolved
        case .wrong: return item.isSolved && !item.isCorrect
        case .type(let name): return item.question.type == name
        }
    }
}
