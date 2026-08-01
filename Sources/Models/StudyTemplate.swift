import Foundation

/// 카드·문제 생성 시 기본 지시문 뒤에 덧붙이는 사용자 템플릿(레고 2026-08-01 요청 — "정리카드나
/// 연습문제 템플릿을 만들거나 수정"). 출력 문법(§O1)·필수 필드(§O2)·절단 상한(§O3)은
/// `StudyOutputParser`가 그대로 의존하는 계약이라 여기서 손대지 않는다 — `instructions`는
/// 항상 `StudyPromptBuilder`의 고정 지시문 뒤에 "추가 지시"로만 붙는다(형식이 깨지지 않게).
struct StudyTemplate: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: StudyItemKind
    /// 자유 문장(예: "쉬운 말로, 초등학생도 알아듣게" · "실무 예시를 하나씩 넣어줘").
    var instructions: String

    init(id: UUID = UUID(), name: String, kind: StudyItemKind, instructions: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.instructions = instructions
    }
}
