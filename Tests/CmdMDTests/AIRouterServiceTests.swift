import XCTest
@testable import CmdMD

final class AIRouterServiceTests: XCTestCase {
    private actor FakeAsking: ClaudeAsking {
        let label: String
        private(set) var calls: [String] = []
        init(label: String) { self.label = label }
        func ask(prompt: String, context: String) async throws -> String {
            calls.append(prompt)
            return label
        }
    }

    func testRoutesToClaudeByDefault() async throws {
        let claude = FakeAsking(label: "클로드 응답")
        let codex = FakeAsking(label: "챗GPT 응답")
        let router = AIRouterService(claude: claude, codex: codex, provider: .claude)
        let out = try await router.ask(prompt: "질문", context: "")
        XCTAssertEqual(out, "클로드 응답")
        let claudeCalls = await claude.calls
        let codexCalls = await codex.calls
        XCTAssertEqual(claudeCalls, ["질문"])
        XCTAssertTrue(codexCalls.isEmpty)
    }

    func testSetProviderSwitchesActiveTarget() async throws {
        let claude = FakeAsking(label: "클로드 응답")
        let codex = FakeAsking(label: "챗GPT 응답")
        let router = AIRouterService(claude: claude, codex: codex, provider: .claude)
        await router.setProvider(.chatgpt)
        let out = try await router.ask(prompt: "질문", context: "")
        XCTAssertEqual(out, "챗GPT 응답")
        let claudeCalls = await claude.calls
        let codexCalls = await codex.calls
        XCTAssertTrue(claudeCalls.isEmpty)
        XCTAssertEqual(codexCalls, ["질문"])
    }

    func testTimeoutOverloadDelegatesToActiveTarget() async throws {
        let claude = FakeAsking(label: "클로드 응답")
        let codex = FakeAsking(label: "챗GPT 응답")
        let router = AIRouterService(claude: claude, codex: codex, provider: .chatgpt)
        let out = try await router.ask(prompt: "질문", context: "", timeout: 999)
        XCTAssertEqual(out, "챗GPT 응답")
    }

    func testAskStreamYieldsActiveTargetResultOnce() async throws {
        let claude = FakeAsking(label: "클로드 응답")
        let codex = FakeAsking(label: "챗GPT 응답")
        let router = AIRouterService(claude: claude, codex: codex, provider: .claude)
        let stream = await router.askStream(prompt: "질문", context: "")
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks, ["클로드 응답"])
    }
}
