import XCTest
@testable import CmdMD

/// "문서에서 할일 찾기" — `TaskExtractor.checkboxTasks(from:)`가 마크다운 체크박스 문법을
/// 정확히 뽑아내는지(완료 항목 제외·줄 번호·다양한 불릿 기호) 확인한다. 순수 함수.
final class TaskExtractorTests: XCTestCase {

    func testExtractsUncheckedCheckboxItems() {
        let markdown = """
        # 제목
        - [ ] 보고서 제출하기
        - [x] 이미 끝난 일
        * [ ] 회의 준비
        + [ ] 다른 불릿 기호도 지원
        """
        let tasks = TaskExtractor.checkboxTasks(from: markdown)
        XCTAssertEqual(tasks.map(\.text), ["보고서 제출하기", "회의 준비", "다른 불릿 기호도 지원"])
        XCTAssertTrue(tasks.allSatisfy { $0.source == .checkbox })
    }

    func testCapitalXAlsoCountsAsChecked() {
        let markdown = "- [X] 대문자 완료 표시도 제외돼야 함"
        XCTAssertTrue(TaskExtractor.checkboxTasks(from: markdown).isEmpty)
    }

    func testLineNumbersAreOneBasedAndAccurate() {
        let markdown = "본문 첫 줄\n\n- [ ] 셋째 줄 항목\n\n- [ ] 다섯째 줄 항목"
        let tasks = TaskExtractor.checkboxTasks(from: markdown)
        XCTAssertEqual(tasks.map(\.lineNumber), [3, 5])
    }

    func testIndentedCheckboxesAreCaptured() {
        let markdown = "- 상위 항목\n  - [ ] 들여쓰기 된 하위 할일"
        let tasks = TaskExtractor.checkboxTasks(from: markdown)
        XCTAssertEqual(tasks.map(\.text), ["들여쓰기 된 하위 할일"])
    }

    func testEmptyCheckboxTextIsExcluded() {
        let markdown = "- [ ] \n- [ ]   \n- [ ] 진짜 할일"
        let tasks = TaskExtractor.checkboxTasks(from: markdown)
        XCTAssertEqual(tasks.map(\.text), ["진짜 할일"])
    }

    func testNoCheckboxesReturnsEmpty() {
        XCTAssertTrue(TaskExtractor.checkboxTasks(from: "그냥 평범한 문단입니다.").isEmpty)
    }

    func testPlainDashListWithoutBracketsIsNotATask() {
        let markdown = "- 그냥 목록 항목(체크박스 아님)"
        XCTAssertTrue(TaskExtractor.checkboxTasks(from: markdown).isEmpty)
    }
}
