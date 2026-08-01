import Foundation

/// 학습도우미 대화(S3) 오케스트레이션 actor(설계 §4.4). 컨텍스트 예산·유한 트리밍은 순수
/// 함수 `ChatContextAssembler`에 위임하고, 이 actor는 (1) 스트림·취소 소유, (2) "턴 유지
/// 개수"를 넘는 오래된 턴을 접는 정책(결정적 또는 옵트인 AI 요약, §4.3), (3) 대화 턴 자체는
/// 콜별 타임아웃 없음·자동 재시도 없음(§4.4 — 카드·퀴즈의 300초+1회 재시도와 다르다)을
/// 책임진다. `ChatContextAssembler`는 여전히 AI를 부르지 않는 순수 함수로 남는다.
actor StudyChatService {
    private let claude: any ClaudeAsking
    /// 세션당 진행 중인 스트림 태스크 — "중단"이 `cancel(sessionId:)`로 여기를 끊는다
    /// (설계 §4.4 "취소는 StudyChatService가 Task를 보관·cancel(), 뷰는 stop()만 호출").
    private var runningTasks: [UUID: Task<TurnOutcome, Never>] = [:]

    /// 옵트인 AI 요약(§4.3) 전용 타임아웃 — 카드·퀴즈(300초)보다 짧다. 대화 턴 자체
    /// (`askStream`)는 이 값과 무관하게 `ClaudeService`의 고정 120초를 그대로 쓴다.
    static let summaryTimeout: TimeInterval = 120

    init(claude: any ClaudeAsking) {
        self.claude = claude
    }

    /// 한 턴을 보낸 결과. `.failed`는 진짜 실패(로그인 필요·타임아웃 등)만 담고, 사용자가
    /// 누른 "중단"은 별도 `.cancelled`로 구분한다 — 호출부가 서로 다른 문구를 보여줘야 해서다.
    enum TurnOutcome {
        case assembled(reply: String, questionTruncated: Bool, trimmed: Bool)
        case noSend(ChatContextAssembler.NoSendReason)
        case cancelled(partial: String)
        case failed(Error)
    }

    /// - Parameters:
    ///   - keepRecentTurns: 이 개수를 넘는 오래된 턴은 보내기 전에 먼저 접는다(§4.2.2
    ///     "턴 유지 개수" — `ChatContextAssembler`의 2단계 트리밍이 굳이 나설 필요가 없도록
    ///     선제적으로 줄여 둔다. 그래도 넘치면 2단계가 안전망으로 다시 접는다).
    ///   - recentTurns: 아직 접히지 않은, 이번 질문 이전까지의 턴(오래된 순서대로). 이번에
    ///     사용자가 막 입력한 질문은 포함하지 않는다 — `question` 파라미터로 따로 받는다.
    ///   - onDelta: 스트리밍 조각마다 MainActor에서 호출된다(뷰 실시간 갱신).
    /// - Returns: 이번 결과 + 접기 정책 적용 후의 `foldedPrefix`/`recentTurns`(호출부가 세션에
    ///   반영). 정책이 접을 게 없었으면 입력과 동일하게 돌아온다.
    func sendTurn(
        sessionId: UUID,
        cap: Int,
        keepRecentTurns: Int,
        pinnedExcerpt: String,
        foldedPrefix: String?,
        recentTurns: [StudyChatTurn],
        question: String,
        aiSummaryEnabled: Bool,
        onDelta: @MainActor @escaping (String) -> Void
    ) async -> (outcome: TurnOutcome, foldedPrefix: String?, recentTurns: [StudyChatTurn]) {
        var folded = foldedPrefix
        var turns = recentTurns

        // §4.3 "조립 시점에만" — ChatContextAssembler는 AI를 부르지 않는 순수 함수라 여기서
        // 미리 접어 둔다. 결과가 여전히 cap을 넘으면 assemble()의 2단계가 안전망으로 재접는다.
        if keepRecentTurns > 0, turns.count > keepRecentTurns {
            let excess = turns.count - keepRecentTurns
            let toFold = Array(turns.prefix(excess))
            turns.removeFirst(excess)
            let text = await fold(toFold, aiSummaryEnabled: aiSummaryEnabled)
            folded = folded.map { $0 + "\n" + text } ?? text
        }

        let result = ChatContextAssembler.assemble(
            cap: cap, pinnedExcerpt: pinnedExcerpt, foldedPrefix: folded,
            recentTurns: turns, question: question)
        guard case .assembled(let context) = result else {
            if case .noSend(let reason) = result {
                return (.noSend(reason), folded, turns)
            }
            return (.noSend(.capTooSmall), folded, turns) // 도달 불가 — Result는 두 case뿐.
        }

        // §4.2.1 "이번 질문" 구획이 원문 그대로 실렸는지로 트리밍 발동 여부를 판정한다
        // (질문이 잘린 경우 = 4단계까지 갔다는 뜻, 항상 전체 트리밍 발생을 포함한다).
        let questionTruncated = !context.contains("[이번 질문]\n\(question)")
        let untrimmedLength = pinnedExcerpt.count + (folded?.count ?? 0)
            + turns.reduce(0) { $0 + $1.text.count } + question.count
            + ChatContextAssembler.framingLength(
                pinnedExcerpt: pinnedExcerpt, foldedPrefix: folded, recentTurns: turns, question: question)
        let trimmed = untrimmedLength > cap

        let outcome = await streamAndCollect(
            sessionId: sessionId, context: context,
            questionTruncated: questionTruncated, trimmed: trimmed, onDelta: onDelta)
        return (outcome, folded, turns)
    }

    /// 진행 중인 스트림을 끊는다(AC #19) — 부분 텍스트는 `sendTurn`이 `.cancelled`로 돌려줘
    /// 호출부가 화면에 보존한다. 해당 세션에 진행 중인 턴이 없으면 아무 일도 하지 않는다.
    func cancel(sessionId: UUID) {
        runningTasks[sessionId]?.cancel()
    }

    // MARK: - 스트리밍(대화 전용 — 120초 고정, 재시도 없음, §4.4)

    private func streamAndCollect(
        sessionId: UUID, context: String, questionTruncated: Bool, trimmed: Bool,
        onDelta: @MainActor @escaping (String) -> Void
    ) async -> TurnOutcome {
        let claude = self.claude
        let task = Task<TurnOutcome, Never> {
            var acc = ""
            let stream = await claude.askStream(prompt: Self.chatSystemPrompt, context: context)
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return .cancelled(partial: acc) }
                    acc += chunk
                    await onDelta(chunk)
                }
                // 취소 시 `AsyncThrowingStream`은 next()가 에러 없이 조용히 끝나 for-await가
                // 정상 종료된 것처럼 루프를 빠져나온다(실측 확인) — 루프 안 체크만으론 "받던
                // 도중 취소"를 놓친다. 루프를 나온 직후 다시 한번 확인해야 정확히 잡는다.
                if Task.isCancelled { return .cancelled(partial: acc) }
                return .assembled(reply: acc, questionTruncated: questionTruncated, trimmed: trimmed)
            } catch {
                if Task.isCancelled { return .cancelled(partial: acc) }
                return .failed(error)
            }
        }
        runningTasks[sessionId] = task
        let outcome = await task.value
        runningTasks[sessionId] = nil
        return outcome
    }

    // MARK: - 오래된 턴 접기(§4.3 — 결정적 기본, 옵트인 AI 요약)

    private func fold(_ turns: [StudyChatTurn], aiSummaryEnabled: Bool) async -> String {
        guard aiSummaryEnabled, !turns.isEmpty else {
            return Self.deterministicFold(turns)
        }
        let transcript = turns.map { "\($0.role == .user ? "사용자" : "도우미"): \($0.text)" }
            .joined(separator: "\n")
        do {
            let summary = try await askWithTimeoutRetry(prompt: Self.foldSummaryPrompt, context: transcript)
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedSummary.isEmpty ? Self.deterministicFold(turns) : trimmedSummary
        } catch {
            // §4.3 "실패 시 조용히 결정적 접기로 폴백" — 에러를 사용자에게 보이지 않는다.
            return Self.deterministicFold(turns)
        }
    }

    private static func deterministicFold(_ turns: [StudyChatTurn]) -> String {
        turns.map { ChatContextAssembler.deterministicFold($0) }.joined(separator: "\n")
    }

    /// 타임아웃 1회만 재시도(`StudyService.askWithTimeoutRetry` 전례와 동일 어법) — 다른
    /// 에러(로그인 안 됨 등)는 그대로 위로 던져 `fold(_:aiSummaryEnabled:)`가 폴백으로 삼는다.
    private func askWithTimeoutRetry(prompt: String, context: String) async throws -> String {
        do {
            return try await claude.ask(prompt: prompt, context: context, timeout: Self.summaryTimeout)
        } catch ClaudeError.timeout {
            return try await claude.ask(prompt: prompt, context: context, timeout: Self.summaryTimeout)
        }
    }

    // MARK: - 프롬프트

    private static let chatSystemPrompt = """
    당신은 학습자와 교재를 함께 읽으며 대화하는 한국어 학습 도우미다. context로 주어진
    [핀 발췌]·[이전 대화 요약]·[대화]·[이번 질문]만 근거로 답하고, 교재에 없는 내용을
    답할 땐 "교재에는 없지만"이라고 밝혀라. [핀 발췌]에 [[p12]]·[[l345]] 같은 위치 표시가
    있으면 관련 부분을 답할 때 그대로 언급해도 좋다. 답은 한국어로, 필요 이상 길게 늘이지 마라.
    """

    private static let foldSummaryPrompt = """
    아래는 학습 대화의 이전 부분이다. 이후 대화에서 문맥으로 쓸 수 있게 핵심만 한국어
    5줄 이내로 요약해라. 새로운 사실을 지어내지 말고 대화에 실제로 나온 내용만 남겨라.
    """
}
