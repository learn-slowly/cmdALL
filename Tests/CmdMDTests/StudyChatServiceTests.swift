import XCTest
@testable import CmdMD

/// S3 셋째 조각 — `StudyChatService`(오케스트레이션 actor)가 §4.2(컨텍스트 조립 위임)·
/// §4.3(접기 정책)·§4.4(스트리밍·취소·재시도 없음)를 지키는지 확인한다. `ChatContextAssembler`
/// 자체 배분·트리밍 계약은 `ChatContextAssemblerTests`가 이미 검증했으므로 여기선 그 결과를
/// 서비스가 올바르게 소비·연동하는지만 본다. 실제 claude CLI는 부르지 않는다.
final class StudyChatServiceTests: XCTestCase {

    // MARK: - 가짜 Claude

    /// `ask`는 즉시 응답(또는 지정 에러), `askStream`은 청크를 하나씩 델타로 내보내며
    /// 취소되면(`onTermination`) 즉시 멈춘다 — 실제 `ClaudeService.askStream` 계약과 동일.
    private actor StreamingClaude: ClaudeAsking {
        private(set) var askCalls: [(prompt: String, context: String)] = []
        private(set) var askStreamCalls: [(prompt: String, context: String)] = []
        var chunks: [String]
        var delayNanoseconds: UInt64
        var askError: Error?
        var streamError: Error?

        init(chunks: [String] = ["안녕", "하세요"], delayNanoseconds: UInt64 = 0,
             askError: Error? = nil, streamError: Error? = nil) {
            self.chunks = chunks
            self.delayNanoseconds = delayNanoseconds
            self.askError = askError
            self.streamError = streamError
        }

        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }

        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            askCalls.append((prompt, context))
            if let askError { throw askError }
            return chunks.joined()
        }

        func askStream(prompt: String, context: String) async -> AsyncThrowingStream<String, Error> {
            askStreamCalls.append((prompt, context))
            let items = chunks
            let delay = delayNanoseconds
            let error = streamError
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for item in items {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        continuation.yield(item)
                    }
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func askStreamCallCount() -> Int { askStreamCalls.count }
        func askCallCount() -> Int { askCalls.count }
    }

    private func collect(onDelta sink: @escaping (String) -> Void) -> (@MainActor (String) -> Void) {
        { chunk in sink(chunk) }
    }

    // MARK: - 정상 전송(AC #17)

    func testSendTurnStreamsReplyAndCallsAskStreamOnce() async {
        let claude = StreamingClaude(chunks: ["안", "녕"])
        let service = StudyChatService(claude: claude)
        var received: [String] = []

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 12,
            pinnedExcerpt: "[[p1]] 교재 내용", foldedPrefix: nil, recentTurns: [],
            question: "질문", aiSummaryEnabled: false
        ) { chunk in received.append(chunk) }

        guard case .assembled(let reply, let questionTruncated, let trimmed) = outcome else {
            return XCTFail("정상 전송이어야 함: \(outcome)")
        }
        XCTAssertEqual(reply, "안녕")
        XCTAssertEqual(received, ["안", "녕"])
        XCTAssertFalse(questionTruncated)
        XCTAssertFalse(trimmed)
        let count = await claude.askStreamCallCount()
        XCTAssertEqual(count, 1)
    }

    /// AC #17 "3턴 이상 대화에서 앞 턴 내용이 전송 컨텍스트에 포함된다" — 서비스가 assemble()에
    /// 넘긴 컨텍스트(=claude에 실제로 간 context)에 이전 턴이 들어있는지 확인.
    func testPriorTurnsAppearInSentContext() async {
        let claude = StreamingClaude(chunks: ["응답"])
        let service = StudyChatService(claude: claude)
        let priorTurns = [
            StudyChatTurn(role: .user, text: "첫 질문"),
            StudyChatTurn(role: .assistant, text: "첫 답변"),
        ]

        _ = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 12,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: priorTurns,
            question: "두 번째 질문", aiSummaryEnabled: false
        ) { _ in }

        let contexts = await claude.askStreamCalls.map(\.context)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertTrue(contexts[0].contains("첫 질문"))
        XCTAssertTrue(contexts[0].contains("첫 답변"))
        XCTAssertTrue(contexts[0].contains("두 번째 질문"))
    }

    // MARK: - no-send(AI 호출 0회)

    func testCapTooSmallReturnsNoSendWithoutCallingAI() async {
        let claude = StreamingClaude()
        let service = StudyChatService(claude: claude)

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 1, keepRecentTurns: 12,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [],
            question: "질문", aiSummaryEnabled: false
        ) { _ in }

        guard case .noSend(.capTooSmall) = outcome else {
            return XCTFail("cap=1은 즉시 noSend여야 함: \(outcome)")
        }
        let count = await claude.askStreamCallCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 트리밍 발동 여부(설계 §4.2.1 안내 문구용)

    func testTrimmedTrueWhenPinExceedsCapButStillFits() async {
        let claude = StreamingClaude(chunks: ["답"])
        let service = StudyChatService(claude: claude)
        let hugePin = String(repeating: "발췌", count: 2_000) // 4,000자 — cap보다 훨씬 큼.

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 500, keepRecentTurns: 12,
            pinnedExcerpt: hugePin, foldedPrefix: nil, recentTurns: [],
            question: "짧은 질문", aiSummaryEnabled: false
        ) { _ in }

        guard case .assembled(_, let questionTruncated, let trimmed) = outcome else {
            return XCTFail("pin만 잘라도 들어가야 함: \(outcome)")
        }
        XCTAssertTrue(trimmed, "원문이 cap을 넘었으니 트리밍이 발동했어야 함")
        XCTAssertFalse(questionTruncated, "질문까지 잘릴 필요는 없었어야 함")
    }

    func testTrimmedFalseWhenEverythingFitsWithoutCutting() async {
        let claude = StreamingClaude(chunks: ["답"])
        let service = StudyChatService(claude: claude)

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 12,
            pinnedExcerpt: "짧은 발췌", foldedPrefix: nil, recentTurns: [],
            question: "짧은 질문", aiSummaryEnabled: false
        ) { _ in }

        guard case .assembled(_, _, let trimmed) = outcome else {
            return XCTFail("여유 있는 cap이면 그대로 들어가야 함: \(outcome)")
        }
        XCTAssertFalse(trimmed)
    }

    /// §4.2.3 4단계 — 다른 모든 걸 비워도 질문 자체가 너무 크면 질문이 잘리고 turn.truncated가 켜진다.
    func testQuestionTruncatedWhenNothingElseToTrim() async {
        let claude = StreamingClaude(chunks: ["답"])
        let service = StudyChatService(claude: claude)
        let hugeQuestion = String(repeating: "질문", count: 500)

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 200, keepRecentTurns: 12,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [],
            question: hugeQuestion, aiSummaryEnabled: false
        ) { _ in }

        guard case .assembled(_, let questionTruncated, let trimmed) = outcome else {
            return XCTFail("질문을 잘라서라도 들어가야 함: \(outcome)")
        }
        XCTAssertTrue(questionTruncated)
        XCTAssertTrue(trimmed)
    }

    // MARK: - 취소(AC #19)

    func testCancelStopsStreamAndReturnsPartialText() async {
        let claude = StreamingClaude(chunks: ["첫", "둘", "셋", "넷"], delayNanoseconds: 200_000_000)
        let service = StudyChatService(claude: claude)
        let sessionId = UUID()

        let sendTask = Task {
            await service.sendTurn(
                sessionId: sessionId, cap: 12_000, keepRecentTurns: 12,
                pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [],
                question: "질문", aiSummaryEnabled: false
            ) { _ in }
        }

        try? await Task.sleep(nanoseconds: 300_000_000) // 첫 청크 이후, 스트림이 끝나기 전.
        await service.cancel(sessionId: sessionId)
        let (outcome, _, _) = await sendTask.value

        guard case .cancelled(let partial) = outcome else {
            return XCTFail("취소 후엔 .cancelled여야 함: \(outcome)")
        }
        XCTAssertFalse(partial.isEmpty, "취소 전까지 받은 텍스트는 남아야 함")
        XCTAssertNotEqual(partial, "첫둘셋넷", "전부 다 받기 전에 끊겼어야 함")
    }

    // MARK: - 실패(취소가 아닌 진짜 에러)

    func testStreamErrorReturnsFailedOutcome() async {
        let claude = StreamingClaude(chunks: [], streamError: ClaudeError.notLoggedIn)
        let service = StudyChatService(claude: claude)

        let (outcome, _, _) = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 12,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [],
            question: "질문", aiSummaryEnabled: false
        ) { _ in }

        guard case .failed(let error) = outcome else {
            return XCTFail("취소가 아닌 에러는 .failed여야 함: \(outcome)")
        }
        guard case ClaudeError.notLoggedIn = error else {
            return XCTFail("ClaudeError.notLoggedIn이어야 함: \(error)")
        }
    }

    // MARK: - 접기 정책(§4.3 — 턴 유지 개수 초과 시)

    func testExcessTurnsFoldDeterministicallyWhenAISummaryOff() async {
        let claude = StreamingClaude(chunks: ["답"])
        let service = StudyChatService(claude: claude)
        let turns = (1...5).map { StudyChatTurn(role: .user, text: "질문\($0)번째 아주 긴 내용입니다") }

        let (_, folded, kept) = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 3,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: turns,
            question: "새 질문", aiSummaryEnabled: false
        ) { _ in }

        XCTAssertEqual(kept.count, 3, "keepRecentTurns=3을 넘는 2개는 접혀야 함")
        XCTAssertNotNil(folded)
        XCTAssertTrue(folded?.contains("질문1번째") ?? false, "접힌 텍스트에 가장 오래된 턴의 흔적이 남아야 함(AC18)")
        let askCount = await claude.askCallCount()
        XCTAssertEqual(askCount, 0, "AI 요약 OFF면 ask() 호출이 없어야 함")
    }

    func testAISummaryFoldsWithAskAndFallsBackOnFailure() async {
        let claude = StreamingClaude(chunks: ["답"], askError: ClaudeError.timeout)
        let service = StudyChatService(claude: claude)
        let turns = (1...5).map { StudyChatTurn(role: .user, text: "질문\($0)번째") }

        let (_, folded, kept) = await service.sendTurn(
            sessionId: UUID(), cap: 12_000, keepRecentTurns: 3,
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: turns,
            question: "새 질문", aiSummaryEnabled: true
        ) { _ in }

        XCTAssertEqual(kept.count, 3)
        // 타임아웃 1회 재시도까지 전부 실패 → 결정적 접기로 폴백(에러 없이 조용히).
        XCTAssertTrue(folded?.contains("질문1번째") ?? false)
        let askCount = await claude.askCallCount()
        XCTAssertEqual(askCount, 2, "타임아웃 1회 재시도까지 정확히 2번 시도해야 함")
    }
}
