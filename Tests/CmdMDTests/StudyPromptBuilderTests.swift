import XCTest
@testable import CmdMD

/// S1 넷째 조각 — `StudyPromptBuilder`가 O1(출력 문법)·O2(필수 필드)·O3(절단 상한) 지시를
/// 빠뜨리지 않고, 위치 태그를 그대로 베끼라는 요구·개수 상한이 반영되는지 확인한다.
final class StudyPromptBuilderTests: XCTestCase {

    // MARK: - 카드

    func testCardPromptIncludesO1FormatMarkers() {
        let prompt = StudyPromptBuilder.cardPrompt(count: 3)

        XCTAssertTrue(prompt.contains("### [카드] 제목"))
        XCTAssertTrue(prompt.contains("> 근거: [[위치표시]]"))
        XCTAssertTrue(prompt.contains("- 핵심 내용 1"))
    }

    func testCardPromptEmbedsRequestedCount() {
        let prompt = StudyPromptBuilder.cardPrompt(count: 5)

        XCTAssertTrue(prompt.contains("최대 5개까지"))
    }

    func testCardPromptClampsNonPositiveCountToOne() {
        XCTAssertTrue(StudyPromptBuilder.cardPrompt(count: 0).contains("최대 1개까지"))
        XCTAssertTrue(StudyPromptBuilder.cardPrompt(count: -3).contains("최대 1개까지"))
    }

    func testCardPromptForbidsFabricationAndDemandsLocatorCopy() {
        let prompt = StudyPromptBuilder.cardPrompt(count: 3)

        XCTAssertTrue(prompt.contains("지어내지 마라"))
        XCTAssertTrue(prompt.contains("그대로(고치지 말고) 복사"))
    }

    func testCardPromptStatesO3Caps() {
        // count는 5로 둬서 "최대 3개까지"가 요청 개수 문구가 아니라 불릿 상한 문구임을 분리 확인.
        let prompt = StudyPromptBuilder.cardPrompt(count: 5)

        XCTAssertTrue(prompt.contains("80자"), "제목 상한")
        XCTAssertTrue(prompt.contains("120자"), "불릿 상한")
        XCTAssertTrue(prompt.contains("200자"), "발췌 상한")
        XCTAssertTrue(prompt.contains("최대 3개까지"), "불릿 개수 상한(O3)")
    }

    // MARK: - 문제

    func testQuizPromptIncludesO1FormatMarkers() {
        let prompt = StudyPromptBuilder.quizPrompt(count: 4)

        XCTAssertTrue(prompt.contains("### [문제 1] 문항 요지"))
        XCTAssertTrue(prompt.contains("type: mcq"))
        XCTAssertTrue(prompt.contains("Q: 질문 본문"))
        XCTAssertTrue(prompt.contains("A: 정답 번호"))
        XCTAssertTrue(prompt.contains("해설: 왜 그 답인지"))
        XCTAssertTrue(prompt.contains("> 근거: [[위치표시]]"))
    }

    func testQuizPromptEmbedsRequestedCount() {
        let prompt = StudyPromptBuilder.quizPrompt(count: 7)

        XCTAssertTrue(prompt.contains("최대 7개까지"))
    }

    func testQuizPromptClampsNonPositiveCountToOne() {
        XCTAssertTrue(StudyPromptBuilder.quizPrompt(count: 0).contains("최대 1개까지"))
        XCTAssertTrue(StudyPromptBuilder.quizPrompt(count: -1).contains("최대 1개까지"))
    }

    func testQuizPromptAllowsNonMCQTypesWithoutOptions() {
        // §O2: type이 mcq가 아니면 보기 없이도 유효 — 프롬프트가 그 자유도를 알려줘야 한다.
        let prompt = StudyPromptBuilder.quizPrompt(count: 3)

        XCTAssertTrue(prompt.contains("mcq는 보기 3~5개 필수"))
    }

    func testQuizPromptStatesO3Caps() {
        let prompt = StudyPromptBuilder.quizPrompt(count: 3)

        XCTAssertTrue(prompt.contains("80자"), "제목 상한")
        XCTAssertTrue(prompt.contains("600자"), "해설 상한")
        XCTAssertTrue(prompt.contains("200자"), "발췌 상한")
    }

    // MARK: - 결정성

    func testPromptsAreDeterministicForSameInput() {
        XCTAssertEqual(StudyPromptBuilder.cardPrompt(count: 3), StudyPromptBuilder.cardPrompt(count: 3))
        XCTAssertEqual(StudyPromptBuilder.quizPrompt(count: 3), StudyPromptBuilder.quizPrompt(count: 3))
    }

    func testCardAndQuizPromptsAreDistinct() {
        XCTAssertNotEqual(StudyPromptBuilder.cardPrompt(count: 3), StudyPromptBuilder.quizPrompt(count: 3))
    }

    // MARK: - 사용자 템플릿 추가 지시(레고 2026-08-01 요청)

    func testCardPromptAppendsExtraInstructionsWhenPresent() {
        let prompt = StudyPromptBuilder.cardPrompt(count: 5, extraInstructions: "쉬운 말로, 초등학생도 알아듣게")
        XCTAssertTrue(prompt.contains("추가 지시(사용자 템플릿): 쉬운 말로, 초등학생도 알아듣게"))
    }

    func testQuizPromptAppendsExtraInstructionsWhenPresent() {
        let prompt = StudyPromptBuilder.quizPrompt(count: 5, extraInstructions: "실무 예시를 하나씩 넣어줘")
        XCTAssertTrue(prompt.contains("추가 지시(사용자 템플릿): 실무 예시를 하나씩 넣어줘"))
    }

    func testEmptyOrWhitespaceExtraInstructionsLeavesPromptUnchanged() {
        let base = StudyPromptBuilder.cardPrompt(count: 5)
        XCTAssertEqual(StudyPromptBuilder.cardPrompt(count: 5, extraInstructions: ""), base)
        XCTAssertEqual(StudyPromptBuilder.cardPrompt(count: 5, extraInstructions: "   \n  "), base)
    }

    func testExtraInstructionsDoNotAlterFixedFormatContract() {
        // §O1~O3 계약은 추가 지시와 무관하게 그대로 남아 있어야 한다(파서 의존).
        let prompt = StudyPromptBuilder.cardPrompt(count: 5, extraInstructions: "표를 많이 써줘")
        XCTAssertTrue(prompt.contains("### [카드] 제목"))
        XCTAssertTrue(prompt.contains("불릿은 최대 3개까지만"))
        XCTAssertTrue(prompt.contains("근거 발췌는 200자 이내"))
    }
}
