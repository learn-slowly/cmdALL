import XCTest
@testable import CmdMD

/// 이미 만들어 둔 문제집 마크다운 가져오기(Q0) — 실제 원본(레고의 미디어교육사 100제)에서
/// 관찰된 형식 변형을 그대로 재현해 건다.
final class QuizImportParserTests: XCTestCase {

    // MARK: - 기본 형태

    func testParsesQuestionWithSectionAnswerAndPage() {
        let md = """
        ## A. 옳은 것 고르기 (1~18)

        **1.** 커뮤니케이션에 대한 설명으로 옳은 것은?
        ① 반드시 사람과 사람 사이에서만 일어난다.
        ② 발화자와 수신자 사이에 의미를 주고받는 것이다.

        # 정답 · 해설

        **1. ②** 의미를 주고받는 것. [[교재.pdf#page=9|📖 p.009]]
        """
        let result = QuizImportParser.parse(md)

        XCTAssertEqual(result.missingNumbers, [])
        XCTAssertEqual(result.questions.count, 1)
        let question = result.questions[0]
        XCTAssertEqual(question.type, "A. 옳은 것 고르기")
        XCTAssertEqual(question.prompt, "커뮤니케이션에 대한 설명으로 옳은 것은?")
        XCTAssertEqual(question.options, ["반드시 사람과 사람 사이에서만 일어난다.",
                                          "발화자와 수신자 사이에 의미를 주고받는 것이다."])
        XCTAssertEqual(question.answer, "2")
        XCTAssertEqual(question.explanation, "의미를 주고받는 것.")
        XCTAssertEqual(question.locator, .page(9))
    }

    /// 원본에 교재 원문 발췌가 없으므로 근거를 지어내지 않는다.
    func testImportedQuestionCarriesNoQuote() {
        let md = """
        **1.** 발문
        ① 가
        ② 나

        # 정답
        **1. ①** 해설.
        """
        let question = QuizImportParser.parse(md).questions[0]
        XCTAssertEqual(question.quote, "")
        XCTAssertFalse(question.unverifiedQuote)
    }

    // MARK: - 원본에서 실제로 관찰된 변형

    /// 보기가 한 줄에 붙어 있는 문항(`① 가  ② 나  ③ 다`).
    func testSplitsOptionsPackedOnOneLine() {
        let md = """
        **3.** 다음 중 옳은 것은?
        ① 광고  ② 제작  ③ 플랫폼  ④ 유통  ⑤ 소비

        # 정답
        **3. ③** 해설.
        """
        let question = QuizImportParser.parse(md).questions[0]
        XCTAssertEqual(question.options, ["광고", "제작", "플랫폼", "유통", "소비"])
        XCTAssertEqual(question.answer, "3")
    }

    /// 보기 문장 안에 동그라미 숫자가 들어 있어도 거기서 쪼개지 않는다.
    /// 원본 5,000문항을 훑어 실제로 1건 발견한 결함(2026-08-05) — `(①~③은 모두 옳다)`.
    func testDoesNotSplitOnCircledNumbersInsideOptionText() {
        let md = """
        **25.** 옳은 것을 모두 고르면?
        ① 프로필 구성
        ② 리스트 명시
        ③ 연결 탐색·조회
        ④ 오프라인 정기 모임 의무화
        ⑤ (①~③은 모두 옳다)

        # 정답
        **25. ⑤** 해설.
        """
        let question = QuizImportParser.parse(md).questions[0]
        XCTAssertEqual(question.options.count, 5)
        XCTAssertEqual(question.options.last, "(①~③은 모두 옳다)")
        XCTAssertEqual(question.answer, "5")
    }

    /// 형식 이름 뒤의 문항 수·범위 꼬리표는 이름이 아니다(원본에 두 표기가 섞여 있다).
    func testStripsCountSuffixFromSectionLabel() {
        for suffix in ["(1~18)", "(18문항)", "( 18문항 )"] {
            let md = """
            ## A. 옳은 것 고르기 \(suffix)

            **1.** 발문
            ① 가
            ② 나

            # 정답
            **1. ①** 해설.
            """
            XCTAssertEqual(QuizImportParser.parse(md).questions.first?.type,
                           "A. 옳은 것 고르기", "꼬리표 \(suffix)를 떼지 못했다")
        }
    }

    /// 이름 안의 괄호는 지키고(숫자로 시작하지 않으면) 꼬리표만 뗀다.
    func testKeepsParenthesesThatAreNotCountSuffix() {
        let md = """
        ## D. 개념·사례 판별 (심화)

        **1.** 발문
        ① 가
        ② 나

        # 정답
        **1. ②** 해설.
        """
        XCTAssertEqual(QuizImportParser.parse(md).questions.first?.type, "D. 개념·사례 판별 (심화)")
    }

    /// 섹션 머리글이 `#`와 `##`로 섞여 있어도 형식 이름을 잃지 않는다.
    func testAcceptsBothHeadingLevelsForSection() {
        let md = """
        # B. 옳지 않은 것 고르기

        **1.** 발문
        ① 가
        ② 나

        # 정답
        **1. ②** 해설.
        """
        XCTAssertEqual(QuizImportParser.parse(md).questions[0].type, "B. 옳지 않은 것 고르기")
    }

    /// 한 줄에 여러 문항의 해설이 나란히 붙어 있는 원본.
    func testParsesMultipleAnswersOnOneLine() {
        let md = """
        **45.** 발문45
        ① 가
        ② 나
        ③ 다

        **46.** 발문46
        ① 라
        ② 마
        ③ 바

        # 정답
        **45. ③** 마흔다섯 해설. [[교재.pdf#page=100|📖 p.100]] **46. ②** 마흔여섯 해설. [[교재.pdf#page=101|📖 p.101]]
        """
        let result = QuizImportParser.parse(md)
        XCTAssertEqual(result.questions.count, 2)
        XCTAssertEqual(result.questions[0].answer, "3")
        XCTAssertEqual(result.questions[0].explanation, "마흔다섯 해설.")
        XCTAssertEqual(result.questions[0].locator, .page(100))
        XCTAssertEqual(result.questions[1].answer, "2")
        XCTAssertEqual(result.questions[1].explanation, "마흔여섯 해설.")
        XCTAssertEqual(result.questions[1].locator, .page(101))
    }

    /// 발문이 여러 줄로 이어지는 문항(보기가 나오기 전까지가 발문).
    func testJoinsMultiLinePrompt() {
        let md = """
        **7.** 다음 사례를 읽고 물음에 답하시오.
        어떤 기관이 캠페인을 벌였다.
        ① 가
        ② 나

        # 정답
        **7. ①** 해설.
        """
        let question = QuizImportParser.parse(md).questions[0]
        XCTAssertEqual(question.prompt, "다음 사례를 읽고 물음에 답하시오.\n어떤 기관이 캠페인을 벌였다.")
        XCTAssertEqual(question.options, ["가", "나"])
    }

    // MARK: - 원본이 부실할 때

    func testReportsMissingWhenAnswerAbsent() {
        let md = """
        **1.** 발문1
        ① 가
        ② 나

        **2.** 발문2
        ① 다
        ② 라

        # 정답
        **1. ②** 해설.
        """
        let result = QuizImportParser.parse(md)
        XCTAssertEqual(result.questions.count, 1)
        XCTAssertEqual(result.missingNumbers, [2])
    }

    /// 정답 번호가 보기 개수를 넘으면 그 문항은 버린다(잘못된 정답을 외우게 하지 않는다).
    func testDropsAnswerOutOfOptionRange() {
        let md = """
        **1.** 발문
        ① 가
        ② 나

        # 정답
        **1. ⑤** 해설.
        """
        let result = QuizImportParser.parse(md)
        XCTAssertEqual(result.questions.count, 0)
        XCTAssertEqual(result.missingNumbers, [1])
    }

    func testMissingPageLinkBecomesUnknownLocator() {
        let md = """
        **1.** 발문
        ① 가
        ② 나

        # 정답
        **1. ①** 쪽 링크가 없는 해설.
        """
        let question = QuizImportParser.parse(md).questions[0]
        XCTAssertEqual(question.locator, .unknown)
        XCTAssertEqual(question.explanation, "쪽 링크가 없는 해설.")
    }

    /// 보기가 하나도 없는 항목은 문제로 세지 않는다(머리글만 있는 안내 문단 등).
    func testIgnoresEntryWithoutOptions() {
        let md = """
        **1.** 보기가 없는 문단

        # 정답
        **1. ①** 해설.
        """
        XCTAssertEqual(QuizImportParser.parse(md).questions.count, 0)
    }

    /// 정답부가 통째로 없는 파일 — 조용히 0건(크래시 없음).
    func testFileWithoutAnswerSection() {
        let md = """
        **1.** 발문
        ① 가
        ② 나
        """
        let result = QuizImportParser.parse(md)
        XCTAssertEqual(result.questions.count, 0)
        XCTAssertEqual(result.missingNumbers, [1])
    }

    // MARK: - 제목

    func testLongPromptIsTruncatedForTitle() {
        let long = String(repeating: "가", count: 60)
        let md = """
        **1.** \(long)
        ① 가
        ② 나

        # 정답
        **1. ①** 해설.
        """
        let title = QuizImportParser.parse(md).questions[0].title
        XCTAssertEqual(title.count, 41)          // 40자 + 말줄임표
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: - 노트로 다시 써도 우리 파서가 읽는가(왕복)

    func testImportedQuestionsSurviveNoteRoundTrip() throws {
        let md = """
        ## A. 옳은 것 고르기 (1~18)

        **1.** 커뮤니케이션이란?
        ① 가
        ② 나

        # 정답
        **1. ②** 해설. [[교재.pdf#page=9|📖 p.009]]
        """
        let questions = QuizImportParser.parse(md).questions
        let folder = URL(fileURLWithPath: "/tmp/노트폴더", isDirectory: true)
        let scope = StudyScope(fileURL: URL(fileURLWithPath: "/tmp/교재.pdf"),
                               kind: .pdf, range: .wholeFile)
        let built = StudyNoteWriter.buildQuestionNote(questions: questions, scope: scope,
                                                      noteFolder: folder, title: "가져온 문제집")

        let parsed = StudyNoteParser.parse(built.body)
        XCTAssertEqual(parsed.kind, .question)
        XCTAssertEqual(parsed.items.count, 1)
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(item.loc, .page(9))
        XCTAssertTrue(item.body.contains("A: 2"))
        XCTAssertTrue(item.body.contains("1) 가"))
        // 근거가 없으므로 근거 줄도 없어야 한다(빈 인용부호를 남기지 않는다).
        XCTAssertFalse(item.body.contains("> 근거:"))
    }
}
