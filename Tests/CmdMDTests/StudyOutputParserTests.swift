import XCTest
@testable import CmdMD

/// S1 다섯째 조각 — `StudyOutputParser`가 O1(문법)·O2(필수 필드)·O3(절단 상한)·O4(인용 검증)·
/// O6(다중 청크 상한)을 정확히 지키는지 확인한다(§5.3 청크→인용 매핑 포함).
final class StudyOutputParserTests: XCTestCase {

    private func chunk(body: String, covering locators: [StudyLocator]) -> StudyChunk {
        StudyChunk(body: body, coveredLocators: locators, charCount: body.count)
    }

    // MARK: - 카드: 기본 파싱 · ### 블록만 추출

    func testParsesValidCardBlock() {
        let body = "[[p12]] 교재 원문 발췌"
        let text = """
        ### [카드] 핵심 개념
        - 첫째 핵심
        - 둘째 핵심
        > 근거: [[p12]] "교재 원문 발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: body, covering: [.page(12)]), maxCount: 10)

        XCTAssertEqual(result.cards.count, 1)
        let card = result.cards[0]
        XCTAssertEqual(card.title, "핵심 개념")
        XCTAssertEqual(card.bullets, ["첫째 핵심", "둘째 핵심"])
        XCTAssertEqual(card.locator, .page(12))
        XCTAssertEqual(card.quote, "교재 원문 발췌")
        XCTAssertFalse(card.unverifiedQuote)
        XCTAssertEqual(result.invalidCitations, 0)
    }

    func testOnlyExtractsHashHashHashBlocksIgnoringPreambleChatter() {
        let body = "[[p1]] 발췌"
        let text = """
        알겠습니다! 아래처럼 카드를 만들어봤어요.

        ### [카드] 제목
        - 핵심
        > 근거: [[p1]] "발췌"

        이해에 도움이 됐으면 좋겠습니다.
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: body, covering: [.page(1)]), maxCount: 10)

        XCTAssertEqual(result.cards.count, 1)
        XCTAssertEqual(result.cards[0].title, "제목")
    }

    func testEmptyTextProducesEmptyResult() {
        let result = StudyOutputParser.parseCards("", chunk: chunk(body: "", covering: []), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertEqual(result.invalidCitations, 0)
    }

    func testTextWithNoHeadingBlocksProducesEmptyResult() {
        let text = "그냥 평범한 문장입니다. 헤딩이 하나도 없어요."

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "본문", covering: []), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
    }

    // MARK: - 카드: 필수 필드 누락 폐기(O2)

    func testDiscardsCardWithEmptyTitle() {
        let text = """
        ### [카드] 
        - 핵심
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
    }

    func testDiscardsCardWithNoBullets() {
        let text = """
        ### [카드] 제목만 있음
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
    }

    func testDiscardsCardWithNoEvidenceLine() {
        let text = """
        ### [카드] 제목
        - 핵심만 있고 근거가 없음
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "본문", covering: []), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
    }

    func testDiscardsCardWithEvidenceLineButNoQuotedText() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[p1]] 따옴표가 없는 발췌
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: [.page(1)]), maxCount: 10)

        XCTAssertTrue(result.cards.isEmpty)
    }

    // MARK: - 카드: O3 절단 상한

    func testFourthBulletIsDiscardedButCardSurvives() {
        let text = """
        ### [카드] 제목
        - 첫째
        - 둘째
        - 셋째
        - 넷째(폐기돼야 함)
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards.count, 1)
        XCTAssertEqual(result.cards[0].bullets, ["첫째", "둘째", "셋째"])
    }

    func testBulletTruncatedTo120Characters() {
        let longBullet = String(repeating: "가", count: 200)
        let text = """
        ### [카드] 제목
        - \(longBullet)
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards[0].bullets[0].count, 120)
    }

    func testTitleTruncatedTo80Characters() {
        let longTitle = String(repeating: "제", count: 200)
        let text = """
        ### [카드] \(longTitle)
        - 핵심
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards[0].title.count, 80)
    }

    func testQuoteTruncatedTo200CharactersAndStillVerifiedIfPrefixMatches() {
        let longQuote = String(repeating: "나", count: 300)
        let body = "[[p1]] " + longQuote
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[p1]] "\(longQuote)"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: body, covering: [.page(1)]), maxCount: 10)

        XCTAssertEqual(result.cards[0].quote.count, 200)
        XCTAssertFalse(result.cards[0].unverifiedQuote, "원문의 접두부라 잘려도 여전히 검증돼야 한다")
    }

    // MARK: - 카드: O4 인용 검증

    func testTagOutsideChunkDowngradesToUnknownAndCountsAsInvalid() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[p99]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: [.page(1)]), maxCount: 10)

        XCTAssertEqual(result.cards.count, 1, "청크 밖 인용이어도 카드 자체는 폐기하지 않는다")
        XCTAssertEqual(result.cards[0].locator, .unknown)
        XCTAssertEqual(result.invalidCitations, 1)
    }

    func testMalformedTagDowngradesAndCounts() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[모름]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards[0].locator, .unknown)
        XCTAssertEqual(result.invalidCitations, 1)
    }

    func testMissingTagDoesNotCountAsInvalidCitation() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: "태그 없이 발췌만"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "태그 없이 발췌만", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards[0].locator, .unknown)
        XCTAssertEqual(result.invalidCitations, 0, "위치를 아예 안 준 것과 잘못 준 것은 다르다")
    }

    func testExplicitUnknownTagDoesNotCountAsInvalidCitation() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌", covering: [.page(1)]), maxCount: 10)

        XCTAssertEqual(result.cards[0].locator, .unknown)
        XCTAssertEqual(result.invalidCitations, 0)
    }

    func testQuoteNotFoundInChunkBodyFlagsUnverifiedButKeepsCard() {
        let text = """
        ### [카드] 제목
        - 핵심
        > 근거: [[p1]] "청크에 실제로는 없는 문장"
        """

        let result = StudyOutputParser.parseCards(
            text, chunk: chunk(body: "[[p1]] 전혀 다른 원문", covering: [.page(1)]), maxCount: 10
        )

        XCTAssertEqual(result.cards.count, 1, "발췌 불일치는 폐기 사유가 아니다(표시만)")
        XCTAssertTrue(result.cards[0].unverifiedQuote)
    }

    // MARK: - 카드: 중복 제목 폐기 · N 초과 폐기(O6)

    func testDuplicateTitleKeepsFirstOccurrenceOnly() {
        let text = """
        ### [카드] 같은 제목
        - 첫 번째 버전
        > 근거: [[?]] "발췌1"

        ### [카드]  같은 제목 
        - 두 번째 버전(폐기돼야 함)
        > 근거: [[?]] "발췌2"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌1 발췌2", covering: []), maxCount: 10)

        XCTAssertEqual(result.cards.count, 1)
        XCTAssertEqual(result.cards[0].bullets, ["첫 번째 버전"])
    }

    func testExceedingMaxCountKeepsOnlyFirstNInOrder() {
        let text = """
        ### [카드] 하나
        - 핵심1
        > 근거: [[?]] "발췌1"

        ### [카드] 둘
        - 핵심2
        > 근거: [[?]] "발췌2"

        ### [카드] 셋
        - 핵심3
        > 근거: [[?]] "발췌3"
        """

        let result = StudyOutputParser.parseCards(text, chunk: chunk(body: "발췌1 발췌2 발췌3", covering: []), maxCount: 2)

        XCTAssertEqual(result.cards.map(\.title), ["하나", "둘"])
    }

    // MARK: - 문제: 기본 파싱 · mcq 보기 개수 검증(O2)

    func testParsesValidMCQQuestion() {
        let body = "[[p5]] 발췌"
        let text = """
        ### [문제 1] 문항 요지
        type: mcq
        Q: 질문 본문
        1) 보기 A
        2) 보기 B
        3) 보기 C
        4) 보기 D
        A: 2
        해설: 왜 2번인지
        > 근거: [[p5]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: body, covering: [.page(5)]), maxCount: 10)

        XCTAssertEqual(result.questions.count, 1)
        let q = result.questions[0]
        XCTAssertEqual(q.title, "문항 요지")
        XCTAssertEqual(q.type, "mcq")
        XCTAssertEqual(q.prompt, "질문 본문")
        XCTAssertEqual(q.options, ["보기 A", "보기 B", "보기 C", "보기 D"])
        XCTAssertEqual(q.answer, "2")
        XCTAssertEqual(q.explanation, "왜 2번인지")
        XCTAssertEqual(q.locator, .page(5))
    }

    func testQuestionHeaderNumberIsArbitraryAndIgnoredForParsing() {
        let text = """
        ### [문제 7] 아무 번호나 와도 됨
        type: OX
        Q: 맞는지 틀린지 고르시오
        A: O
        해설: 이유
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.questions.count, 1)
        XCTAssertEqual(result.questions[0].title, "아무 번호나 와도 됨")
    }

    func testMCQWithTooFewOptionsIsDiscarded() {
        let text = """
        ### [문제 1] 요지
        type: mcq
        Q: 질문
        1) 보기A
        2) 보기B
        A: 1
        해설: 이유
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.questions.isEmpty, "mcq인데 보기가 2개뿐이면 폐기(O2: 3~5개 필수)")
    }

    func testMCQWithTooManyOptionsIsDiscarded() {
        let text = """
        ### [문제 1] 요지
        type: mcq
        Q: 질문
        1) A
        2) B
        3) C
        4) D
        5) E
        6) F
        A: 1
        해설: 이유
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.questions.isEmpty)
    }

    func testNonMCQTypeIsValidWithoutAnyOptions() {
        let text = """
        ### [문제 1] 요지
        type: 단답
        Q: 질문
        A: 정답
        해설: 이유
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.questions.count, 1)
        XCTAssertTrue(result.questions[0].options.isEmpty)
    }

    // MARK: - 문제: 필수 필드 누락 폐기(O2)

    func testDiscardsQuestionMissingQLine() {
        let text = """
        ### [문제 1] 요지
        type: mcq
        1) A
        2) B
        3) C
        A: 1
        해설: 이유
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.questions.isEmpty)
    }

    func testDiscardsQuestionMissingExplanation() {
        let text = """
        ### [문제 1] 요지
        type: OX
        Q: 질문
        A: O
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertTrue(result.questions.isEmpty)
    }

    // MARK: - 문제: O3 상한(해설 600자)

    func testExplanationTruncatedTo600Characters() {
        let longExplanation = String(repeating: "다", count: 900)
        let text = """
        ### [문제 1] 요지
        type: OX
        Q: 질문
        A: O
        해설: \(longExplanation)
        > 근거: [[?]] "발췌"
        """

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 10)

        XCTAssertEqual(result.questions[0].explanation.count, 600)
    }

    // MARK: - 문제: N 초과 폐기(O6) — 카드와 동일 로직 재확인

    func testQuestionsExceedingMaxCountAreTrimmedFromTheEnd() {
        func block(_ n: Int) -> String {
            """
            ### [문제 \(n)] 문제\(n)
            type: OX
            Q: 질문\(n)
            A: O
            해설: 이유\(n)
            > 근거: [[?]] "발췌\(n)"
            """
        }
        let text = [block(1), block(2), block(3)].joined(separator: "\n\n")

        let result = StudyOutputParser.parseQuestions(text, chunk: chunk(body: "발췌", covering: []), maxCount: 2)

        XCTAssertEqual(result.questions.map(\.title), ["문제1", "문제2"])
    }
}
