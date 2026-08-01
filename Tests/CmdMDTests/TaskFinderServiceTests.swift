import XCTest
@testable import CmdMD

/// "문서에서 할일 찾기" 오케스트레이션 — `TaskFinderService`가 체크박스(항상)·AI(본문이
/// 있을 때만) 두 경로를 올바르게 합치고, AI 실패 시에도 체크박스 결과는 살아남는지 확인한다.
final class TaskFinderServiceTests: XCTestCase {

    private actor ScriptedClaude: ClaudeAsking {
        enum Mode { case succeed(String), fail }
        private let mode: Mode
        private(set) var callCount = 0
        init(_ mode: Mode) { self.mode = mode }
        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            callCount += 1
            switch mode {
            case .succeed(let response): return response
            case .fail: throw ClaudeError.failed("가짜 실패")
            }
        }
    }

    func testEmptyBodySkipsAICallAndReturnsCheckboxOnly() async {
        let claude = ScriptedClaude(.succeed(#"["안 불려야 함"]"#))
        let service = TaskFinderService(claude: claude)
        let result = await service.findTasks(body: "", isMarkdown: true)
        XCTAssertTrue(result.candidates.isEmpty)
        let calls = await claude.callCount
        XCTAssertEqual(calls, 0, "본문이 비면 AI를 부르지 않는다")
    }

    func testCombinesCheckboxAndAIResults() async {
        let claude = ScriptedClaude(.succeed(#"["회의 준비하기"]"#))
        let service = TaskFinderService(claude: claude)
        let body = "- [ ] 보고서 제출\n본문 설명"
        let result = await service.findTasks(body: body, isMarkdown: true)
        XCTAssertEqual(Set(result.candidates.map(\.text)), ["보고서 제출", "회의 준비하기"])
        XCTAssertNil(result.aiError)
    }

    func testNonMarkdownSkipsCheckboxParsingEvenIfBracketSyntaxPresent() async {
        let claude = ScriptedClaude(.succeed("[]"))
        let service = TaskFinderService(claude: claude)
        // office 변환 결과에 우연히 "- [ ] ..."와 닮은 텍스트가 있어도 체크박스로 취급하지 않는다.
        let body = "- [ ] 이건 오피스 변환 본문일 뿐"
        let result = await service.findTasks(body: body, isMarkdown: false)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testAIFailureKeepsCheckboxCandidatesAndSetsNotice() async {
        let claude = ScriptedClaude(.fail)
        let service = TaskFinderService(claude: claude)
        let body = "- [ ] 체크박스는 살아남아야 함"
        let result = await service.findTasks(body: body, isMarkdown: true)
        XCTAssertEqual(result.candidates.map(\.text), ["체크박스는 살아남아야 함"])
        XCTAssertNotNil(result.aiError)
    }

    func testAIExistingTextsAreExcludedFromCombinedResult() async {
        let claude = ScriptedClaude(.succeed(#"["체크박스 항목", "새 항목"]"#))
        let service = TaskFinderService(claude: claude)
        let body = "- [ ] 체크박스 항목\n본문"
        let result = await service.findTasks(body: body, isMarkdown: true)
        // AI가 이미 체크박스로 찾은 것과 같은 문장을 다시 내놓아도 중복 없이 한 번만.
        XCTAssertEqual(result.candidates.filter { $0.text == "체크박스 항목" }.count, 1)
        XCTAssertTrue(result.candidates.contains { $0.text == "새 항목" })
    }
}
