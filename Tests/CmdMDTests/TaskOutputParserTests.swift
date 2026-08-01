import XCTest
@testable import CmdMD

/// "문서에서 할일 찾기" — `TaskOutputParser`가 AI 응답 JSON 배열을 안전하게 후보로
/// 바꾸는지(형식 붕괴·중복·길이 상한·기존 항목 제외) 확인한다. 순수 함수.
final class TaskOutputParserTests: XCTestCase {

    func testParsesValidJSONArray() {
        let raw = #"응답: ["보고서 제출", "회의 준비"]"#
        let tasks = TaskOutputParser.parseAIResponse(raw)
        XCTAssertEqual(tasks.map(\.text), ["보고서 제출", "회의 준비"])
        XCTAssertTrue(tasks.allSatisfy { $0.source == .ai })
    }

    func testMalformedResponseReturnsEmpty() {
        XCTAssertTrue(TaskOutputParser.parseAIResponse("그냥 설명만 하고 배열이 없음").isEmpty)
    }

    func testEmptyArrayReturnsEmpty() {
        XCTAssertTrue(TaskOutputParser.parseAIResponse("[]").isEmpty)
    }

    func testExcludesTextsAlreadyFoundByCheckbox() {
        let raw = #"["이미 있는 항목", "새 항목"]"#
        let tasks = TaskOutputParser.parseAIResponse(raw, excluding: ["이미 있는 항목"])
        XCTAssertEqual(tasks.map(\.text), ["새 항목"])
    }

    func testDeduplicatesWithinAIListItself() {
        let raw = #"["같은 항목", "같은 항목", "다른 항목"]"#
        let tasks = TaskOutputParser.parseAIResponse(raw)
        XCTAssertEqual(tasks.map(\.text), ["같은 항목", "다른 항목"])
    }

    func testDropsEmptyAndOverlongItems() {
        let tooLong = String(repeating: "가", count: TaskOutputParser.maxTextLength + 1)
        let raw = "[\"\", \"   \", \"정상 항목\", \"\(tooLong)\"]"
        let tasks = TaskOutputParser.parseAIResponse(raw)
        XCTAssertEqual(tasks.map(\.text), ["정상 항목"])
    }

    func testCapsAtMaxItems() {
        let items = (0..<(TaskOutputParser.maxItems + 10)).map { "항목\($0)" }
        let data = try! JSONEncoder().encode(items)
        let raw = String(data: data, encoding: .utf8)!
        let tasks = TaskOutputParser.parseAIResponse(raw)
        XCTAssertEqual(tasks.count, TaskOutputParser.maxItems)
    }

    func testExtractsArrayEvenWithSurroundingProse() {
        let raw = "물론입니다! 찾은 할일은 다음과 같습니다:\n[\"항목1\"]\n감사합니다."
        XCTAssertEqual(TaskOutputParser.parseAIResponse(raw).map(\.text), ["항목1"])
    }
}
