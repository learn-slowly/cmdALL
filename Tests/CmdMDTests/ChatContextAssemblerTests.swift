import XCTest
@testable import CmdMD

/// S3 둘째 조각 — `ChatContextAssembler`가 설계 §4.2(예산 배분·유한 트리밍·no-send 계약)를
/// 정확히 지키는지 확인한다. 순수 함수라 AI·파일 접근 없이 전부 결정적으로 검증 가능하다.
final class ChatContextAssemblerTests: XCTestCase {

    // MARK: - §4.2.2 배분 공식 (budgetSplit)

    func testBudgetSplitMatchesWorkedExample() {
        // 설계 문서 §4.2.2 검산 예시: cap=12,000 → reserve=960 → cb=11,040 → 6,624/1,104/2,760/552.
        let split = ChatContextAssembler.budgetSplit(cap: 12_000, framingLength: 0)

        XCTAssertEqual(split.reserve, 960)
        XCTAssertEqual(split.contentBudget, 11_040)
        XCTAssertEqual(split.pinBudget, 6_624)
        XCTAssertEqual(split.foldedBudget, 1_104)
        XCTAssertEqual(split.recentBudget, 2_760)
        XCTAssertEqual(split.questionBudget, 552)
    }

    func testReserveRoundsUp() {
        // cap=100 → 100×0.08=8.0(정확히 나눠떨어짐) → 8. cap=101 → 8.08 → ceil → 9.
        XCTAssertEqual(ChatContextAssembler.budgetSplit(cap: 100, framingLength: 0).reserve, 8)
        XCTAssertEqual(ChatContextAssembler.budgetSplit(cap: 101, framingLength: 0).reserve, 9)
    }

    func testContentBudgetShrinksWhenFramingExceedsReserve() {
        // cap=1,000 → reserve=80. framingLength=200(>reserve)이면 80 대신 200을 뺀다.
        let split = ChatContextAssembler.budgetSplit(cap: 1_000, framingLength: 200)
        XCTAssertEqual(split.contentBudget, 800)
    }

    func testRemainderIsAlwaysAddedToPinBudget() {
        // cap=13, framingLength=0 → reserve=2, cb=11 → pin0=6·folded=1·recent=2·question=0,
        // 합=9, 잔여 2는 전부 pin에 가산(§4.2.2 5단계) → pinBudget=8.
        let split = ChatContextAssembler.budgetSplit(cap: 13, framingLength: 0)
        XCTAssertEqual(split.pinBudget, 8)
        // 배분 4구획의 합은 항상 contentBudget과 정확히 같다(AC31 e).
        XCTAssertEqual(
            split.pinBudget + split.foldedBudget + split.recentBudget + split.questionBudget,
            split.contentBudget)
    }

    func testBudgetSplitSumEqualsContentBudgetAcrossManyCaps() {
        // AC31(e) — 임의의 cap 여러 개에서도 항상 성립해야 한다.
        for cap in [1, 2, 13, 100, 1_000, 12_000, 50_000, 123_457] {
            let split = ChatContextAssembler.budgetSplit(cap: cap, framingLength: 0)
            XCTAssertEqual(
                split.pinBudget + split.foldedBudget + split.recentBudget + split.questionBudget,
                split.contentBudget,
                "cap=\(cap)")
        }
    }

    // MARK: - no-send 게이트

    func testFramingAtOrAboveCapReturnsNoSend() {
        // AC31(b) — 프레이밍 P만으로도 cap을 채우거나 넘으면 배분 없이 즉시 실패.
        let p = ChatContextAssembler.framingLength(
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "안녕하세요")

        XCTAssertEqual(
            ChatContextAssembler.assemble(cap: p, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "안녕하세요"),
            .noSend(.capTooSmall))
        XCTAssertEqual(
            ChatContextAssembler.assemble(cap: max(1, p - 1), pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "안녕하세요"),
            .noSend(.capTooSmall))
    }

    func testZeroOrNegativeCapReturnsNoSend() {
        XCTAssertEqual(
            ChatContextAssembler.assemble(cap: 0, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "질문"),
            .noSend(.capTooSmall))
        XCTAssertEqual(
            ChatContextAssembler.assemble(cap: -5, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "질문"),
            .noSend(.capTooSmall))
    }

    func testQuestionBudgetZeroReturnsNoSend() {
        // AC31(d) — 프레이밍은 통과하지만 이번 질문 몫이 0으로 떨어지는 아주 작은 cap.
        let p = ChatContextAssembler.framingLength(
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "질문")
        let cap = p + 5 // contentBudget=5 → question=floor(5×0.05)=0.

        XCTAssertEqual(
            ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: "질문"),
            .noSend(.capTooSmall))
    }

    // MARK: - 사후조건·no-op 통과

    func testAssembledAlwaysSatisfiesCap() {
        let cases: [(pin: String, folded: String?, turns: [StudyChatTurn], question: String, cap: Int)] = [
            ("교재 발췌 내용", "이전 요약", [StudyChatTurn(role: .user, text: "질문1"), StudyChatTurn(role: .assistant, text: "답변1")], "이번 질문", 500),
            (String(repeating: "핀", count: 3000), nil, [], String(repeating: "질", count: 3000), 800),
            ("", nil, [], "짧은 질문", 12_000),
        ]

        for testCase in cases {
            let result = ChatContextAssembler.assemble(
                cap: testCase.cap, pinnedExcerpt: testCase.pin, foldedPrefix: testCase.folded,
                recentTurns: testCase.turns, question: testCase.question)
            switch result {
            case .assembled(let s):
                XCTAssertLessThanOrEqual(s.count, testCase.cap)
            case .noSend:
                break // 못 보낸 것 자체는 사후조건 위반이 아니다 — 아래 별도 테스트가 성공 케이스를 확인한다.
            }
        }
    }

    func testNoOpPassthroughWhenAlreadyUnderCap() {
        let turn = StudyChatTurn(role: .user, text: "간단한 질문")
        let result = ChatContextAssembler.assemble(
            cap: 100_000, pinnedExcerpt: "발췌", foldedPrefix: "요약", recentTurns: [turn], question: "이번 질문")

        guard case .assembled(let s) = result else {
            return XCTFail("여유로운 cap이면 트리밍 없이 그대로 조립되어야 한다")
        }
        XCTAssertTrue(s.contains("발췌"))
        XCTAssertTrue(s.contains("요약"))
        XCTAssertTrue(s.contains("간단한 질문"))
        XCTAssertTrue(s.contains("이번 질문"))
        XCTAssertFalse(s.contains("…(생략)"), "자를 필요가 없었으므로 생략 표시가 없어야 한다")
    }

    func testAssembleIsDeterministic() {
        let turns = [StudyChatTurn(role: .user, text: "질문"), StudyChatTurn(role: .assistant, text: String(repeating: "답", count: 400))]
        let a = ChatContextAssembler.assemble(cap: 300, pinnedExcerpt: String(repeating: "핀", count: 500), foldedPrefix: "요약", recentTurns: turns, question: "다음 질문")
        let b = ChatContextAssembler.assemble(cap: 300, pinnedExcerpt: String(repeating: "핀", count: 500), foldedPrefix: "요약", recentTurns: turns, question: "다음 질문")
        XCTAssertEqual(a, b)
    }

    // MARK: - §4.2.3 트리밍 순서 (1단계 요약 → 2단계 턴 → 3단계 핀 → 4단계 질문)

    func testFoldedPrefixTrimmedBeforeTurnsAreRemoved() {
        let bigFolded = String(repeating: "요", count: 500)
        let turn = StudyChatTurn(role: .user, text: "짧은턴내용")
        let p = ChatContextAssembler.framingLength(
            pinnedExcerpt: "", foldedPrefix: bigFolded, recentTurns: [turn], question: "질문")
        let cap = p + turn.text.count + "질문".count + 60 // 요약을 좀 줄이면 충분히 들어갈 정도.

        let result = ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: "", foldedPrefix: bigFolded, recentTurns: [turn], question: "질문")

        guard case .assembled(let s) = result else {
            return XCTFail("요약만 줄이면 충분히 들어가야 한다(cap=\(cap))")
        }
        XCTAssertTrue(s.contains("짧은턴내용"), "턴은 지워지면 안 된다 — 요약이 먼저 잘려야 한다")
        XCTAssertFalse(s.contains(bigFolded), "요약 원문 500자가 그대로 남아있으면 안 된다(잘렸어야 함)")
        XCTAssertLessThanOrEqual(s.count, cap)
    }

    func testOldestTurnsFoldedDeterministicallyWhenStillOverBudget() {
        // AC18 — 밀려난 턴은 삭제가 아니라 §4.3 결정적 접기("역할: 앞 200자…")로 대체된다.
        let oldTurn = StudyChatTurn(role: .user, text: String(repeating: "옛", count: 300))
        let newTurn = StudyChatTurn(role: .assistant, text: "최근답변")
        let p = ChatContextAssembler.framingLength(
            pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [oldTurn, newTurn], question: "질문")
        // 요약(folded)이 애초에 없으니 1단계는 no-op — 바로 2단계(턴 제거)로 넘어가야 한다.
        let cap = p + newTurn.text.count + "질문".count + 210 // 오래된 턴 접기(≤201자)까지만 들어갈 정도.

        let result = ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [oldTurn, newTurn], question: "질문")

        guard case .assembled(let s) = result else {
            return XCTFail("오래된 턴을 접으면 충분히 들어가야 한다(cap=\(cap))")
        }
        XCTAssertTrue(s.contains("최근답변"), "최근 턴은 남아 있어야 한다")
        XCTAssertTrue(s.contains("사용자: " + String(String(repeating: "옛", count: 300).prefix(200)) + "…"), "밀려난 턴은 정확히 §4.3 형식으로 접혀야 한다")
        XCTAssertFalse(s.contains(String(repeating: "옛", count: 201)), "밀려난 턴의 201번째 글자부터는 남아있으면 안 된다")
    }

    func testEarlierTurnsSurviveInSomeForm() {
        // AC17 — 3턴 이상 대화에서 앞 턴 내용이 전송 컨텍스트에 (원문이든 접힌 형태든) 포함된다.
        let turns = [
            StudyChatTurn(role: .user, text: "TURN-ONE-MARKER"),
            StudyChatTurn(role: .assistant, text: "TURN-TWO-MARKER"),
            StudyChatTurn(role: .user, text: "TURN-THREE-MARKER"),
        ]
        let result = ChatContextAssembler.assemble(cap: 5_000, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: turns, question: "질문")

        guard case .assembled(let s) = result else { return XCTFail("여유로운 cap에서는 항상 조립돼야 한다") }
        XCTAssertTrue(s.contains("TURN-ONE-MARKER"))
        XCTAssertTrue(s.contains("TURN-TWO-MARKER"))
        XCTAssertTrue(s.contains("TURN-THREE-MARKER"))
    }

    func testPinnedExcerptTrimmedToFloorAsLastButOneResort() {
        let bigPin = String(repeating: "핀", count: 2_000)
        let p = ChatContextAssembler.framingLength(pinnedExcerpt: bigPin, foldedPrefix: nil, recentTurns: [], question: "질문")
        let cap = p + 200 // 핀 발췌를 상당히 줄여야만 들어가는 좁은 예산.

        let result = ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: bigPin, foldedPrefix: nil, recentTurns: [], question: "질문")

        guard case .assembled(let s) = result else {
            return XCTFail("핀 발췌를 줄이면 들어가야 한다(cap=\(cap))")
        }
        XCTAssertTrue(s.contains("…(생략)"), "핀 발췌가 실제로 잘렸어야 한다")
        XCTAssertFalse(s.contains(bigPin), "핀 발췌 2,000자가 그대로 남아있으면 안 된다")
        XCTAssertTrue(s.contains("질문"), "질문은 아직 자를 필요가 없었으면 그대로 남아야 한다")
        XCTAssertLessThanOrEqual(s.count, cap)
    }

    func testQuestionTrimmedOnlyAsFinalResort() {
        let bigQuestion = String(repeating: "질", count: 2_000)
        let p = ChatContextAssembler.framingLength(pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: bigQuestion)
        let cap = p + 100 // 핀·요약·턴이 아예 없으니 질문 자체를 줄일 수밖에 없다.

        let result = ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: "", foldedPrefix: nil, recentTurns: [], question: bigQuestion)

        guard case .assembled(let s) = result else {
            return XCTFail("질문을 줄이면 들어가야 한다(cap=\(cap))")
        }
        XCTAssertTrue(s.contains("…(생략)"))
        XCTAssertFalse(s.contains(bigQuestion))
        XCTAssertLessThanOrEqual(s.count, cap)
    }

    // MARK: - 트리밍으로도 못 맞추는 경우 (AC31 c)

    func testTightCapWithHeavyContentCanFailToFitAfterAllStages() {
        let bigPin = String(repeating: "가", count: 2_000)
        let bigQuestion = String(repeating: "나", count: 2_000)
        let p = ChatContextAssembler.framingLength(pinnedExcerpt: bigPin, foldedPrefix: nil, recentTurns: [], question: bigQuestion)

        var found = false
        for cap in stride(from: p + 1, through: p + 400, by: 1) {
            let result = ChatContextAssembler.assemble(cap: cap, pinnedExcerpt: bigPin, foldedPrefix: nil, recentTurns: [], question: bigQuestion)
            if result == .noSend(.cannotFitAfterTrim) {
                found = true
                break
            }
            // 어느 경우든 크래시 없이 유효한 결과만 나와야 한다.
            if case .assembled(let s) = result {
                XCTAssertLessThanOrEqual(s.count, cap)
            }
        }
        XCTAssertTrue(found, "생략 표시 오버헤드 때문에 4단계를 다 거쳐도 못 맞추는 cap이 이 구간에 있어야 한다")
    }

    // MARK: - 극단값 (AC31 a) — 무크래시

    func testExtremeCapValuesDoNotCrash() {
        let turns = [StudyChatTurn(role: .user, text: "질문"), StudyChatTurn(role: .assistant, text: "답변")]
        for cap in [1, 2, 959, 960, 961] {
            let result = ChatContextAssembler.assemble(
                cap: cap, pinnedExcerpt: "발췌", foldedPrefix: "요약", recentTurns: turns, question: "이번 질문")
            switch result {
            case .assembled(let s):
                XCTAssertLessThanOrEqual(s.count, cap, "cap=\(cap)")
            case .noSend:
                break
            }
        }
    }
}
