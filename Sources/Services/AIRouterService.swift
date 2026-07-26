import Foundation

/// 현재 로그인된 AI(클로드 또는 챗GPT) 한쪽으로만 질의를 위임하는 라우터.
/// CleanupService·WikiIngestService·WikiRulesService·RagService는 이 라우터를 ClaudeAsking으로
/// 주입받는다 — 사용자가 설정에서 로그인 계정을 바꿔도(setProvider) 이 서비스들을 다시 만들
/// 필요가 없다. "계정 둘 다 있어도 한 번에 하나만 쓴다"는 요구를 여기 한 곳에서 구현한다.
/// claude/codex를 프로토콜 타입으로 받아 테스트가 실제 CLI 없이 가짜를 주입할 수 있게 한다.
actor AIRouterService: ClaudeAsking {
    private let claude: any ClaudeAsking
    private let codex: any ClaudeAsking
    private var provider: AIProvider

    init(claude: any ClaudeAsking, codex: any ClaudeAsking, provider: AIProvider) {
        self.claude = claude
        self.codex = codex
        self.provider = provider
    }

    /// 설정 화면에서 로그인 전환 시 호출 — 이후 모든 질의가 새 provider로 간다.
    func setProvider(_ provider: AIProvider) {
        self.provider = provider
    }

    /// 테스트·디버깅용 조회.
    var currentProvider: AIProvider { provider }

    private var active: any ClaudeAsking { provider == .claude ? claude : codex }

    func ask(prompt: String, context: String) async throws -> String {
        try await active.ask(prompt: prompt, context: context)
    }

    func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
        try await active.ask(prompt: prompt, context: context, timeout: timeout)
    }

    /// "Ask Claude" 패널이 쓰는 스트리밍 — 활성 provider의 askStream으로 위임.
    func askStream(prompt: String, context: String) async -> AsyncThrowingStream<String, Error> {
        await active.askStream(prompt: prompt, context: context)
    }
}
