import Foundation

/// 할일 후보가 어디서 왔는지 — 화면에 배지로 구분해 보여준다.
enum TaskSourceKind: String, Equatable, Codable {
    /// 문서에 이미 `- [ ] ...` 체크박스로 써둔 것(정확함, AI 미개입).
    case checkbox
    /// AI가 본문을 읽고 "이것도 할일 같다"고 찾아준 것(놓치거나 잘못 찾을 수 있음).
    case ai
}

/// 문서에서 찾은 할일 후보 하나. 순수 데이터 — 실제로 Todoist에 보내기 전까지는
/// 화면(`TaskFinderView`)의 체크 상태만 바뀔 뿐 어디에도 쓰이지 않는다.
struct TaskCandidate: Equatable, Identifiable {
    let id: UUID
    let text: String
    let source: TaskSourceKind
    /// 체크박스 유래면 원본 문서의 1-based 줄 번호(참고용), AI 유래는 위치를 모르므로 nil.
    let lineNumber: Int?

    init(id: UUID = UUID(), text: String, source: TaskSourceKind, lineNumber: Int? = nil) {
        self.id = id
        self.text = text
        self.source = source
        self.lineNumber = lineNumber
    }
}
