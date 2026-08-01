import Foundation

/// 학습도우미 대화(S3) 한 세션 — 메모리에만 있다(설계 §4.1). 앱이 비정상 종료(크래시)됐을
/// 때만 사본이 `StudyChatDraft`(§4.7)로 잠시 디스크에 남는다.
///
/// 설계 문서의 세션 모델(§4.1)에는 스트림 취소용 `Task`도 포함되지만, `Task`는
/// `Equatable`이 아니라 이 struct에 넣으면 순수 값 타입으로 테스트하기 어려워진다.
/// 스트림·취소 소유는 `StudyChatService`(예정)가 세션 id로 따로 관리하고(§4.7.7
/// "책임 분리"와 같은 원칙), 이 struct는 화면에 그릴 수 있는 순수 데이터만 담는다.
struct StudyChatSession: Equatable {
    let id: UUID
    var sourceURL: URL?
    /// 교재에서 골라 고정한 발췌 — 대화 내내 컨텍스트에 실린다(§4.2.2 "pin" 배정 대상).
    var pinnedExcerpt: String
    var turns: [StudyChatTurn]
    /// 오래된 턴들을 접어 만든 요약. 아직 접을 게 없으면 nil(§4.2.3 1단계·§4.3 대상).
    var foldedPrefix: String?

    init(
        id: UUID = UUID(),
        sourceURL: URL? = nil,
        pinnedExcerpt: String = "",
        turns: [StudyChatTurn] = [],
        foldedPrefix: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.pinnedExcerpt = pinnedExcerpt
        self.turns = turns
        self.foldedPrefix = foldedPrefix
    }
}

/// 대화 한 턴 — `StudyChatSession.turns`의 원소.
struct StudyChatTurn: Equatable {
    enum Role: String, Equatable {
        case user
        case assistant
    }

    var role: Role
    var text: String
    /// 이번 턴을 Claude에 보낼 때 예산 때문에 잘렸으면 true(`ChatContextAssembler`의
    /// 4단계 — 실제로 잘리는 건 항상 "이번 질문" 턴뿐이다).
    var truncated: Bool = false
}
