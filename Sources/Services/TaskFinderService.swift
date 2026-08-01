import Foundation

/// "문서에서 할일 찾기" 오케스트레이션 — 체크박스(로컬, 항상)와 AI(본문이 있을 때만) 두
/// 경로를 합쳐 후보 목록을 만든다. AI 실패는 전체 실패로 취급하지 않는다: 체크박스로 찾은
/// 것만이라도 보여주고 안내 문구만 남긴다(전례: `StudyService`의 부분 성공 원칙).
actor TaskFinderService {
    private let claude: any ClaudeAsking

    init(claude: any ClaudeAsking) {
        self.claude = claude
    }

    struct Result: Equatable {
        let candidates: [TaskCandidate]
        let aiError: String?
    }

    /// - Parameters:
    ///   - body: `ContentExtractor.body(for:)`가 뽑아준 문서 본문(종류 무관 — office는 kordoc
    ///     변환, pdf는 텍스트 추출 등 호출부가 이미 처리한 결과).
    ///   - isMarkdown: 체크박스 파싱을 시도할지(마크다운 원문에만 의미 있는 문법이라 다른
    ///     종류는 건너뛴다 — office 변환 마크다운도 체크박스 문법이 없어 제외).
    func findTasks(body: String, isMarkdown: Bool) async -> Result {
        let checkboxTasks = isMarkdown ? TaskExtractor.checkboxTasks(from: body) : []
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            return Result(candidates: checkboxTasks, aiError: nil)
        }
        do {
            let prompt = TaskPromptBuilder.detectPrompt(existingTexts: checkboxTasks.map(\.text))
            let response = try await claude.ask(prompt: prompt, context: body, timeout: 120)
            let aiTasks = TaskOutputParser.parseAIResponse(response, excluding: checkboxTasks.map(\.text))
            return Result(candidates: checkboxTasks + aiTasks, aiError: nil)
        } catch {
            return Result(candidates: checkboxTasks,
                           aiError: "AI가 추가로 찾아보는 데 실패했습니다. 체크박스로 써둔 항목만 표시합니다.")
        }
    }
}
