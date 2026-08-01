import Foundation

/// "문서에서 할일 찾기"로 Todoist에 실제로 보낸 기록 한 건 — 앱 안에서만 보는 이력(로컬 로그).
/// Todoist 쪽 실제 할일과는 `todoistTaskId`로만 느슨하게 연결되고, 이 기록 자체를 지운다고
/// Todoist의 할일이 지워지지는 않는다(반대도 마찬가지 — 순수 "언제 어디서 뭘 보냈나" 이력).
struct SentTaskRecord: Equatable, Codable, Identifiable {
    let id: UUID
    let text: String
    /// 어떤 문서에서 찾았는지(파일명만, 표시용).
    let sourceFileName: String?
    let sourcePath: String?
    let sentAt: Date
    /// 생성 응답에서 받은 Todoist 쪽 id. 응답 디코드에 실패해도 전송 자체는 성공일 수 있어 nil 허용.
    let todoistTaskId: String?
}
