import XCTest
@testable import CmdMD

final class CodexServiceTests: XCTestCase {
    // MARK: - classify

    func testClassifyDetectsNotLoggedIn() {
        let e = CodexService.classify(exitCode: 1, message: "Error: not logged in. Run `codex login`.")
        guard case .notLoggedIn = e else { return XCTFail("기대: notLoggedIn, 실제: \(e)") }
    }

    func testClassifyDetectsUnauthorized401() {
        let e = CodexService.classify(exitCode: 1, message: "HTTP 401: unauthorized")
        guard case .notLoggedIn = e else { return XCTFail("기대: notLoggedIn, 실제: \(e)") }
    }

    func testClassifyDetectsCreditExhausted() {
        let e = CodexService.classify(exitCode: 1, message: "You have exceeded your usage limit / rate limit.")
        guard case .creditExhausted = e else { return XCTFail("기대: creditExhausted, 실제: \(e)") }
    }

    func testClassifyFallsBackToFailedWithMessagePrefix() {
        let e = CodexService.classify(exitCode: 2, message: "boom: something unexpected broke")
        guard case .failed(let msg) = e else { return XCTFail("기대: failed, 실제: \(e)") }
        XCTAssertTrue(msg.contains("boom"))
    }

    // MARK: - makeArguments

    func testMakeArgumentsPassesPromptAsLastArgAndKeepsReadOnlySandbox() {
        let args = CodexService.makeArguments(prompt: "이 문서 요약해줘")
        XCTAssertEqual(args.last, "이 문서 요약해줘")
        XCTAssertTrue(args.contains("exec"))
        XCTAssertTrue(args.contains("--json"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("--ignore-user-config"))
    }

    // MARK: - parseEvents (실측 codex exec --json JSONL 기반)

    func testParseEventsExtractsAgentMessage() {
        let jsonl = """
        {"type":"thread.started","thread_id":"t1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Hi! 👋"}}
        {"type":"turn.completed","usage":{"input_tokens":1}}
        """
        let parsed = CodexService.parseEvents(jsonl)
        XCTAssertEqual(parsed.agentMessage, "Hi! 👋")
        XCTAssertNil(parsed.errorMessage)
    }

    func testParseEventsExtractsTurnFailedMessage() {
        let jsonl = """
        {"type":"thread.started","thread_id":"t1"}
        {"type":"turn.started"}
        {"type":"error","message":"{\\"type\\":\\"error\\",\\"status\\":400}"}
        {"type":"turn.failed","error":{"message":"model not supported"}}
        """
        let parsed = CodexService.parseEvents(jsonl)
        XCTAssertNil(parsed.agentMessage)
        XCTAssertEqual(parsed.errorMessage, "model not supported")
    }

    func testParseEventsIgnoresUnknownLinesAndBlankLines() {
        let jsonl = "not json\n\n{\"type\":\"thread.started\",\"thread_id\":\"t1\"}\n"
        let parsed = CodexService.parseEvents(jsonl)
        XCTAssertNil(parsed.agentMessage)
        XCTAssertNil(parsed.errorMessage)
    }

    func testParseEventsKeepsLastAgentMessageWhenMultiple() {
        let jsonl = """
        {"type":"item.completed","item":{"type":"agent_message","text":"첫 응답"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"최종 응답"}}
        """
        let parsed = CodexService.parseEvents(jsonl)
        XCTAssertEqual(parsed.agentMessage, "최종 응답")
    }
}
