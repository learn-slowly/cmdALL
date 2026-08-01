import Foundation

/// 대화 도중 앱이 비정상 종료(크래시)됐을 때만 다음 실행까지 남는 임시 초안(설계 §4.7).
/// 볼트 마크다운이 아니라 앱 지원 폴더의 JSON 파일 하나로 저장된다(`appDir/study-chat-draft.json`,
/// §4.7.2) — 읽고 쓰는 책임은 `StudyChatDraftStore`(예정)가 갖고, 이 struct는 그 내용 모양만 정의한다.
struct StudyChatDraft: Codable, Equatable {
    /// 인코딩 형식 버전. 저장된 값이 이것과 다르면 `StudyChatDraftStore`가 읽지 않고
    /// 복구 시트 없이 조용히 지운다(§4.7.5 2번).
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionId: UUID
    /// 원본 파일 경로 — 파일이 옮겨지거나 지워졌을 수 있어 optional(§4.7.5 4번).
    var sourcePath: String?
    /// 복구 시트 문구("《원본 이름》, 7월 30일 21:14")에 쓸 표시용 이름.
    var sourceDisplayName: String?
    var pinnedExcerpt: String
    var turns: [StudyChatDraftTurn]
    var updatedAt: Date
    var appBuild: String
}

/// 대화 한 턴 — `StudyChatDraft.turns`의 원소.
struct StudyChatDraftTurn: Codable, Equatable {
    var role: String
    var text: String
    var truncated: Bool
}
