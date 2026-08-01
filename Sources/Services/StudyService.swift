import Foundation

/// 카드·문제 생성 오케스트레이션 actor(§Q1, 설계 문서 "코어는 `StudyService`(actor)"). 범위(`StudyScope`)를
/// `StudySourceLoader`로 읽어 `StudyChunker`로 자르고, 청크마다 `StudyPromptBuilder` 프롬프트를
/// `ClaudeAsking`(가짜 주입 가능)에 보낸 뒤 `StudyOutputParser`로 해석해 모은다(O1~O6).
/// 이 조각(StudyService)은 생성까지만 책임지고, 노트 파일 쓰기는 `StudyNoteWriter`(다음 조각)의 몫이다.
actor StudyService {
    private let claude: any ClaudeAsking
    private let sourceLoader: StudySourceLoader

    /// 카드·퀴즈 전용 타임아웃(§4.4) — 대화(`askStream`)의 120초 고정과 다른, 위키 인제스트와
    /// 같은 300초 상한. 타임아웃 1회만 재시도한다(`WikiIngestService.askWithRetry` 전례).
    static let timeout: TimeInterval = 300

    init(claude: any ClaudeAsking, sourceLoader: StudySourceLoader) {
        self.claude = claude
        self.sourceLoader = sourceLoader
    }

    /// 한 번의 생성 실행 결과.
    struct Outcome<Item: Equatable>: Equatable {
        let items: [Item]
        /// O4 — 청크 밖 인용이거나 형식이 깨진 태그 수(모든 청크 합산).
        let invalidCitations: Int
        let chunkCount: Int
        let succeededChunkCount: Int
        /// O5 "원문 보관" — 재요청까지 해도 유효 항목 0건이었던 청크의 본문(추후 재시도 UI·디버깅용,
        /// 이 조각에서는 저장만 하고 아직 쓰지 않는다).
        let failedChunkBodies: [String]
    }

    enum GenerationError: Error, Equatable {
        /// AC3 — 선택 범위의 총 본문이 공백(청크 0개)이면 AI를 아예 부르지 않는다.
        case emptyContent
        /// O5 — 모든 청크가 재요청까지 실패했을 때만(청크 일부 실패는 부분 성공으로 반환).
        case allChunksFailed
    }

    func generateCards(scope: StudyScope, count: Int, chunkBudget: Int) async throws -> Outcome<StudyCard> {
        try await run(
            scope: scope, count: count, chunkBudget: chunkBudget,
            prompt: StudyPromptBuilder.cardPrompt,
            parse: { text, chunk, maxCount in
                let result = StudyOutputParser.parseCards(text, chunk: chunk, maxCount: maxCount)
                return (result.cards, result.invalidCitations)
            },
            title: \.title
        )
    }

    func generateQuestions(scope: StudyScope, count: Int, chunkBudget: Int) async throws -> Outcome<StudyQuestion> {
        try await run(
            scope: scope, count: count, chunkBudget: chunkBudget,
            prompt: StudyPromptBuilder.quizPrompt,
            parse: { text, chunk, maxCount in
                let result = StudyOutputParser.parseQuestions(text, chunk: chunk, maxCount: maxCount)
                return (result.questions, result.invalidCitations)
            },
            title: \.title
        )
    }

    // MARK: - 공통 오케스트레이션(카드·문제 동일 흐름)

    private func run<Item: Equatable>(
        scope: StudyScope, count: Int, chunkBudget: Int,
        prompt: (Int) -> String,
        parse: (_ text: String, _ chunk: StudyChunk, _ maxCount: Int) -> (items: [Item], invalidCitations: Int),
        title: (Item) -> String
    ) async throws -> Outcome<Item> {
        let segments = await sourceLoader.segments(for: scope)
        let chunks = StudyChunker.chunks(from: segments, budget: chunkBudget)
        guard !chunks.isEmpty else { throw GenerationError.emptyContent } // AC3: 본문 0자 → 호출 0회.

        let requested = max(1, count)
        // §O6: 청크당 ceil(N/C) — 반올림 때문에 청크 합이 N을 넘을 수 있어 아래서 전체를 다시 N으로 자른다.
        let perChunkCount = Int((Double(requested) / Double(chunks.count)).rounded(.up))

        var allItems: [Item] = []
        var invalidCitations = 0
        var failedBodies: [String] = []

        for chunk in chunks {
            let promptText = prompt(perChunkCount)
            var raw = try await askWithTimeoutRetry(prompt: promptText, context: chunk.body)
            var result = parse(raw, chunk, perChunkCount)

            if result.items.isEmpty { // §O5: 유효 0건 → 같은 청크 정확히 1회만 재요청.
                raw = try await askWithTimeoutRetry(prompt: promptText, context: chunk.body)
                result = parse(raw, chunk, perChunkCount)
            }

            guard !result.items.isEmpty else {
                failedBodies.append(chunk.body) // §O5: 두 번째도 0건 → 그 청크만 실패 + 원문 보관.
                continue
            }
            allItems.append(contentsOf: result.items)
            invalidCitations += result.invalidCitations
        }

        // §O5: 전체 실패는 모든 청크가 실패했을 때만.
        guard failedBodies.count < chunks.count else { throw GenerationError.allChunksFailed }

        return Outcome(
            items: Self.capAndDedupe(allItems, by: title, maxCount: requested), // §O6: 정규화 중복 폐기 + N개 상한.
            invalidCitations: invalidCitations,
            chunkCount: chunks.count,
            succeededChunkCount: chunks.count - failedBodies.count,
            failedChunkBodies: failedBodies
        )
    }

    /// 타임아웃 1회 재시도 — 실데이터에서 청크 하나가 300초 경계에 걸려 그 청크 전체가
    /// 무산되는 것을 방어한다(`CleanupService.askWithRetry`·`WikiIngestService` 전례). 타임아웃이
    /// 아닌 다른 에러(로그인 안 됨·크레딧 소진 등)는 그대로 위로 던져 전체 생성을 멈춘다(AC10).
    private func askWithTimeoutRetry(prompt: String, context: String) async throws -> String {
        do {
            return try await claude.ask(prompt: prompt, context: context, timeout: Self.timeout)
        } catch ClaudeError.timeout {
            return try await claude.ask(prompt: prompt, context: context, timeout: Self.timeout)
        }
    }

    /// §O6 "제목 정규화 중복 폐기 · 초과분 앞에서부터 N개 채택" — 청크를 넘나드는 전역 상한.
    /// 청크 내부 상한(`StudyOutputParser.capAndDedupe`, private)과 알고리즘은 같되 적용 범위가 다르다.
    private static func capAndDedupe<Item>(_ items: [Item], by title: (Item) -> String, maxCount: Int) -> [Item] {
        var seenTitles = Set<String>()
        var deduped: [Item] = []
        for item in items {
            let key = title(item).trimmingCharacters(in: .whitespaces).lowercased()
            guard !seenTitles.contains(key) else { continue }
            seenTitles.insert(key)
            deduped.append(item)
        }
        return Array(deduped.prefix(max(0, maxCount)))
    }
}
