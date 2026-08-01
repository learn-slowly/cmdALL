import XCTest
@testable import CmdMD

/// S1 여섯째 조각 — `StudyService`(오케스트레이션 actor)가 §O5(재요청·부분 성공)·§O6(다중 청크
/// 상한)·AC3(본문 0자 → 호출 0회)·AC10(에러는 던지고 크래시 없음)을 지키는지 확인한다.
/// 실제 claude CLI는 부르지 않고 `ScriptedClaude`(가짜)를 주입한다.
final class StudyServiceTests: XCTestCase {

    // MARK: - 가짜 Claude

    /// 응답을 순서대로 하나씩 소비하는 가짜. 큐가 비면 빈 문자열(= 파싱 실패)을 돌려준다.
    private actor ScriptedClaude: ClaudeAsking {
        private(set) var calls: [(prompt: String, context: String, timeout: TimeInterval)] = []
        private var responses: [Result<String, Error>]

        init(_ responses: [Result<String, Error>]) {
            self.responses = responses
        }

        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }

        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            calls.append((prompt, context, timeout))
            guard !responses.isEmpty else { return "" }
            switch responses.removeFirst() {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }

        func callCount() -> Int { calls.count }
        func recordedPrompts() -> [String] { calls.map(\.prompt) }
        func recordedContexts() -> [String] { calls.map(\.context) }
    }

    // MARK: - 헬퍼

    private func makeScope(dir: URL, name: String, content: String) -> StudyScope {
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return StudyScope(fileURL: url, kind: .markdown, range: .wholeFile)
    }

    private func validCardResponse(title: String, tag: String = "[[l1]]", quote: String = "발췌") -> String {
        """
        ### [카드] \(title)
        - 핵심 1
        - 핵심 2
        > 근거: \(tag) "\(quote)"
        """
    }

    private func validQuestionResponse(title: String, tag: String = "[[l1]]", quote: String = "발췌") -> String {
        """
        ### [문제 1] \(title)
        type: mcq
        Q: 질문 본문
        1) 보기 A
        2) 보기 B
        3) 보기 C
        A: 1
        해설: 설명
        > 근거: \(tag) "\(quote)"
        """
    }

    // MARK: - AC3: 본문 0자 → 호출 0회

    func testEmptyContentThrowsWithoutCallingAI() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "빈글.md", content: "   \n\n  ")
        let fake = ScriptedClaude([])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        do {
            _ = try await service.generateCards(scope: scope, count: 3, chunkBudget: 1000)
            XCTFail("빈 본문은 emptyContent를 던져야 한다")
        } catch StudyService.GenerationError.emptyContent {
            // 기대대로.
        }
        let count = await fake.callCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 정상 경로

    func testGeneratesCardsFromSingleChunkAndReportsSuccessCounts() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([.success(validCardResponse(title: "핵심 개념", tag: "[[l1]]"))])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateCards(scope: scope, count: 5, chunkBudget: 1000)

        XCTAssertEqual(outcome.items.map(\.title), ["핵심 개념"])
        XCTAssertEqual(outcome.chunkCount, 1)
        XCTAssertEqual(outcome.succeededChunkCount, 1)
        XCTAssertEqual(outcome.invalidCitations, 0)
        XCTAssertTrue(outcome.failedChunkBodies.isEmpty)
        let prompts = await fake.recordedPrompts()
        XCTAssertTrue(prompts[0].contains("최대 5개까지"), "청크 1개면 ceil(5/1)=5여야 한다")
        let contexts = await fake.recordedContexts()
        XCTAssertTrue(contexts[0].contains("교재 원문 발췌 내용"), "context(stdin)에 청크 본문이 실려야 한다")
    }

    func testGenerateQuestionsUsesQuizFormatAndParsesQuestions() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([.success(validQuestionResponse(title: "문항", tag: "[[l1]]"))])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateQuestions(scope: scope, count: 3, chunkBudget: 1000)

        XCTAssertEqual(outcome.items.map(\.title), ["문항"])
        XCTAssertEqual(outcome.items[0].type, "mcq")
        XCTAssertEqual(outcome.items[0].options.count, 3)
    }

    // MARK: - O5: 유효 0건 → 정확히 1회 재요청

    func testEmptyParseRetriesOnceThenSucceeds() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([
            .success("알겠습니다! 그런데 형식을 안 지켰어요."), // 첫 시도: ### 블록 없음 → 유효 0건.
            .success(validCardResponse(title: "재시도 성공", tag: "[[l1]]")),
        ])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateCards(scope: scope, count: 3, chunkBudget: 1000)

        XCTAssertEqual(outcome.items.map(\.title), ["재시도 성공"])
        XCTAssertEqual(outcome.succeededChunkCount, 1)
        let count = await fake.callCount()
        XCTAssertEqual(count, 2)
    }

    func testEmptyParseTwiceFailsThatChunkAndThrowsWhenAllChunksFail() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([
            .success("형식 붕괴 1"),
            .success("형식 붕괴 2"),
        ])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        do {
            _ = try await service.generateCards(scope: scope, count: 3, chunkBudget: 1000)
            XCTFail("유일한 청크가 두 번 다 실패하면 allChunksFailed를 던져야 한다")
        } catch StudyService.GenerationError.allChunksFailed {
            // 기대대로.
        }
        let count = await fake.callCount()
        XCTAssertEqual(count, 2, "정확히 1회만 재요청해야 한다(무한 재시도 금지)")
    }

    // MARK: - 다중 청크: 부분 성공 · 전역 상한/중복 폐기(O6)

    /// 헤딩 두 개로 세그먼트 2개를 만들고, 예산을 좁혀 청크도 2개로 쪼갠다.
    private func twoChunkScope(dir: URL) -> StudyScope {
        let filler1 = String(repeating: "본문", count: 100) // 200자.
        let filler2 = String(repeating: "내용", count: 100)
        let content = "# 하나\n\(filler1)\n# 둘\n\(filler2)"
        return makeScope(dir: dir, name: "장.md", content: content)
    }

    func testPartialSuccessAcrossChunksAggregatesAndKeepsFailedChunkBody() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = twoChunkScope(dir: dir)
        let fake = ScriptedClaude([
            .success(validCardResponse(title: "첫 청크 카드", tag: "[[l1]]")), // 청크1: 1회에 성공.
            .success("형식 붕괴 1"), // 청크2: 1차 실패.
            .success("형식 붕괴 2"), // 청크2: 재요청도 실패.
        ])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateCards(scope: scope, count: 5, chunkBudget: 260)

        XCTAssertEqual(outcome.chunkCount, 2)
        XCTAssertEqual(outcome.succeededChunkCount, 1)
        XCTAssertEqual(outcome.items.map(\.title), ["첫 청크 카드"])
        XCTAssertEqual(outcome.failedChunkBodies.count, 1)
        XCTAssertTrue(outcome.failedChunkBodies[0].contains("내용"), "실패한 청크의 원문이 보관돼야 한다(O5)")
    }

    func testGlobalCapAndDedupeLimitsAcrossChunksToRequestedCount() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = twoChunkScope(dir: dir)
        // 청크당 ceil(3/2)=2개 요청 — 두 청크 다 같은 제목 "중복 카드"를 하나씩, 서로 다른 제목도 하나씩 낸다.
        let chunk1Response = """
        ### [카드] 중복 카드
        - 핵심
        > 근거: [[l1]] "발췌1"

        ### [카드] 청크1 전용
        - 핵심
        > 근거: [[l1]] "발췌1"
        """
        let chunk2Response = """
        ### [카드] 중복 카드
        - 핵심
        > 근거: [[l1]] "발췌2"

        ### [카드] 청크2 전용
        - 핵심
        > 근거: [[l1]] "발췌2"
        """
        let fake = ScriptedClaude([.success(chunk1Response), .success(chunk2Response)])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateCards(scope: scope, count: 3, chunkBudget: 260)

        XCTAssertLessThanOrEqual(outcome.items.count, 3, "§O6: 전체 상한 N을 넘으면 안 된다")
        let titles = outcome.items.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "§O6: 정규화 중복 제목은 전역에서 한 번만 남아야 한다")
        XCTAssertEqual(titles.filter { $0 == "중복 카드" }.count, 1)
    }

    // MARK: - 타임아웃: 1회만 재시도

    func testTimeoutRetriesOnceThenSucceeds() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([
            .failure(ClaudeError.timeout),
            .success(validCardResponse(title: "타임아웃 이후 성공", tag: "[[l1]]")),
        ])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        let outcome = try await service.generateCards(scope: scope, count: 3, chunkBudget: 1000)

        XCTAssertEqual(outcome.items.map(\.title), ["타임아웃 이후 성공"])
        let count = await fake.callCount()
        XCTAssertEqual(count, 2)
    }

    func testTimeoutTwiceThrowsAndStopsGeneration() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = twoChunkScope(dir: dir) // 청크 2개 — 두 번째 청크는 호출되면 안 된다.
        let fake = ScriptedClaude([
            .failure(ClaudeError.timeout),
            .failure(ClaudeError.timeout),
        ])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        do {
            _ = try await service.generateCards(scope: scope, count: 3, chunkBudget: 260)
            XCTFail("두 번째 타임아웃도 그대로 던져야 한다")
        } catch ClaudeError.timeout {
            // 기대대로 — AC10: 크래시 없이 던지기만.
        }
        let count = await fake.callCount()
        XCTAssertEqual(count, 2, "청크1의 타임아웃 재시도(2회) 후 즉시 멈추고 청크2는 호출하지 않아야 한다")
    }

    // MARK: - 그 외 에러는 재시도 없이 즉시 전파(AC10)

    func testNonTimeoutErrorPropagatesImmediatelyWithoutRetry() async throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let scope = makeScope(dir: dir, name: "장.md", content: "# 하나\n교재 원문 발췌 내용")
        let fake = ScriptedClaude([.failure(ClaudeError.notLoggedIn)])
        let service = StudyService(claude: fake, sourceLoader: StudySourceLoader(kordoc: KordocService()))

        do {
            _ = try await service.generateCards(scope: scope, count: 3, chunkBudget: 1000)
            XCTFail("notLoggedIn은 그대로 전파돼야 한다")
        } catch ClaudeError.notLoggedIn {
            // 기대대로.
        }
        let count = await fake.callCount()
        XCTAssertEqual(count, 1, "타임아웃이 아니므로 재시도하면 안 된다")
    }
}
