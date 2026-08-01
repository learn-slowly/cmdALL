import Foundation

/// "문서에서 할일 찾기" AI 호출용 프롬프트(순수 함수). 이미 체크박스로 찾아둔 항목은
/// 다시 찾지 말라고 알려줘 중복 후보를 줄인다.
enum TaskPromptBuilder {
    static func detectPrompt(existingTexts: [String]) -> String {
        let existingList = existingTexts.isEmpty ? "(없음)" : existingTexts.map { "- \($0)" }.joined(separator: "\n")
        return """
        아래 문서 본문을 읽고, 아직 끝나지 않은 할일(다음에 해야 할 일·마감이 있는 일·준비물·연락할 것 등)로 볼 수 있는 문장을 찾아라.
        이미 체크박스로 표시돼 다시 찾을 필요 없는 항목:
        \(existingList)

        규칙:
        - 결과는 다른 설명 없이 JSON 문자열 배열로만 답하라. 예: ["다음 주 화요일까지 보고서 제출", "김대리에게 연락"]
        - 할일이 하나도 없으면 빈 배열 []만 답하라.
        - 각 항목은 한국어 한 문장으로, 너무 길지 않게(50자 이내 권장) 요약해서 적어라.
        - 이미 끝난 일이나 단순 정보(사실 서술)는 넣지 마라.
        """
    }
}
