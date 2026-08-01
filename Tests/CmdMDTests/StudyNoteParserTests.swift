import XCTest
@testable import CmdMD

/// 학습도우미 복습(S2) — `StudyNoteParser`가 §3.3(앵커 정규 문법)·§3.6(중복·손상 정책)을
/// 정확히 지키는지 확인한다. `StudyNoteWriter`가 만든 노트를 그대로 되읽어(왕복) 검증하고,
/// 손으로 구성한 손상 케이스로 강건성도 확인한다.
final class StudyNoteParserTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let noteFolder = URL(fileURLWithPath: "/Users/lego/vault/study")

    private func makeSource() -> URL { URL(fileURLWithPath: "/Users/lego/vault/study/자격증.pdf") }

    private func sequentialUUIDGenerator() -> () -> UUID {
        var counter = 0
        return {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        }
    }

    // MARK: - 카드 노트 왕복

    func testParsesCardNoteItemsRoundTrip() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let cards = [
            StudyCard(title: "첫째 개념", bullets: ["핵심 1", "핵심 2"], locator: .page(12),
                      quote: "발췌 하나", unverifiedQuote: false),
            StudyCard(title: "둘째 개념", bullets: ["핵심 3"], locator: .pageRange(20, 22),
                      quote: "발췌 둘", unverifiedQuote: true),
        ]
        let result = StudyNoteWriter.buildCardNote(
            cards: cards, scope: scope, noteFolder: noteFolder, title: "자격증 카드",
            now: fixedDate, makeUUID: sequentialUUIDGenerator())

        let parsed = StudyNoteParser.parse(result.body)
        XCTAssertEqual(parsed.kind, .card)
        XCTAssertEqual(parsed.studyID?.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(parsed.items.count, 2)

        XCTAssertEqual(parsed.items[0].uid, result.itemUIDs[0])
        XCTAssertEqual(parsed.items[0].title, "첫째 개념")
        XCTAssertEqual(parsed.items[0].loc, .page(12))
        XCTAssertTrue(parsed.items[0].body.contains("핵심 1"))
        XCTAssertTrue(parsed.items[0].body.contains("발췌 하나"))
        XCTAssertFalse(parsed.items[0].body.contains("둘째 개념"), "다음 항목 내용이 섞이면 안 된다")
        XCTAssertTrue(parsed.items[0].lineText.hasPrefix("<!-- study item="))

        XCTAssertEqual(parsed.items[1].loc, .pageRange(20, 22))
        XCTAssertTrue(parsed.items[1].body.contains("핵심 3"))
    }

    // MARK: - 문제 노트 왕복

    func testParsesQuestionNoteItemsRoundTrip() {
        let scope = StudyScope(fileURL: makeSource(), kind: .markdown, range: .wholeFile)
        let questions = [
            StudyQuestion(title: "문항 1", type: "mcq", prompt: "질문?", options: ["A", "B", "C"],
                          answer: "1", explanation: "설명", locator: .line(345),
                          quote: "근거", unverifiedQuote: false),
        ]
        let result = StudyNoteWriter.buildQuestionNote(
            questions: questions, scope: scope, noteFolder: noteFolder, title: "문제",
            now: fixedDate, makeUUID: sequentialUUIDGenerator())

        let parsed = StudyNoteParser.parse(result.body)
        XCTAssertEqual(parsed.kind, .question)
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].title, "문항 1")
        XCTAssertEqual(parsed.items[0].loc, .line(345))
        XCTAssertTrue(parsed.items[0].body.contains("Q: 질문?"))
        XCTAssertTrue(parsed.items[0].body.contains("A: 1"))
        XCTAssertTrue(parsed.items[0].body.contains("해설: 설명"))
    }

    // MARK: - 대화 노트는 항목 없음(복습 대상 아님)

    func testChatNoteHasNoItems() {
        var session = StudyChatSession(sourceURL: makeSource(), pinnedExcerpt: "핀 발췌")
        session.turns = [StudyChatTurn(role: .user, text: "질문")]
        let result = StudyNoteWriter.buildChatNote(
            session: session, sourceKind: .pdf, noteFolder: noteFolder, title: "대화",
            now: fixedDate, makeUUID: sequentialUUIDGenerator())

        let parsed = StudyNoteParser.parse(result.body)
        XCTAssertNil(parsed.kind, "study_kind: chat은 StudyItemKind(card/question)에 없어 nil로 남는다")
        XCTAssertTrue(parsed.items.isEmpty)
    }

    // MARK: - frontmatter/study_id 없으면 항목 0건(§3.6)

    func testPlainMarkdownWithoutFrontmatterHasNoItems() {
        let parsed = StudyNoteParser.parse("# 그냥 메모\n아무 내용")
        XCTAssertNil(parsed.studyID)
        XCTAssertTrue(parsed.items.isEmpty)
    }

    // MARK: - §3.6 노트 안 중복 uid: 첫 번째만

    func testDuplicateUIDInSameNoteKeepsFirstOnly() {
        let uid = "00000000-0000-0000-0000-000000000099"
        let content = """
        ---
        study_id: 00000000-0000-0000-0000-000000000001
        study_kind: card
        ---

        <!-- study item=\(uid) src=a.pdf loc=p1 due=2026-08-01 ivl=0 ease=2.50 reps=0 lapses=0 -->
        ### [카드] 첫 번째
        - 불릿

        <!-- study item=\(uid) src=a.pdf loc=p2 due=2026-08-02 ivl=1 ease=2.55 reps=1 lapses=0 -->
        ### [카드] 두 번째(같은 uid, 무시돼야 함)
        - 불릿
        """
        let parsed = StudyNoteParser.parse(content)
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].title, "첫 번째")
    }

    // MARK: - §3.3 위반 줄은 건너뛰고 나머지는 정상 처리(AC #26)

    func testBrokenAnchorLineSkippedOthersStillParsed() {
        let content = """
        ---
        study_id: 00000000-0000-0000-0000-000000000001
        study_kind: card
        ---

        <!-- study item=이건-유효한-uuid-아님 src=a.pdf loc=p1 due=2026-08-01 ivl=0 ease=2.50 reps=0 lapses=0 -->
        ### [카드] 깨진 항목(무시돼야 함)
        - 불릿

        <!-- study item=00000000-0000-0000-0000-000000000002 src=a.pdf loc=p2 due=2026-08-02 ivl=1 ease=2.55 reps=1 lapses=0 -->
        ### [카드] 정상 항목
        - 불릿
        """
        let parsed = StudyNoteParser.parse(content)
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].title, "정상 항목")
    }

    // MARK: - 미지 키 보존(§3.3)

    func testUnknownKeysAreParsedAsExtraTokens() {
        let line = "<!-- study item=00000000-0000-0000-0000-000000000003 src=a.pdf loc=p1 " +
            "due=2026-08-01 ivl=0 ease=2.50 reps=0 lapses=0 future_key=xyz -->"
        let parsed = StudyNoteParser.parseAnchorLine(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.extraTokens, ["future_key=xyz"])
    }

    // MARK: - 채점 쓰기(§3.6) — 앵커 줄 치환

    func testReplacingAnchorLineSucceedsWhenLineUnchanged() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let cards = [StudyCard(title: "제목", bullets: ["불릿"], locator: .page(1),
                                quote: "발췌", unverifiedQuote: false)]
        let result = StudyNoteWriter.buildCardNote(
            cards: cards, scope: scope, noteFolder: noteFolder, title: "카드",
            now: fixedDate, makeUUID: sequentialUUIDGenerator())
        let uid = result.itemUIDs[0]
        let original = StudyNoteParser.parse(result.body).items[0]

        // 앵커의 due=는 yyyy-MM-dd(날짜만) 정밀도로만 저장되므로, 기대값도 자정 기준으로 맞춘다.
        let newState = StudyReviewState(
            due: Calendar.current.startOfDay(for: fixedDate.addingTimeInterval(86_400)),
            interval: 1, ease: 2.55, reps: 1, lapses: 0)
        let replaced = StudyNoteParser.replacingAnchorLine(
            in: result.body, itemUID: uid, expectedLineText: original.lineText, newState: newState)
        XCTAssertNotNil(replaced)
        let reparsed = StudyNoteParser.parse(replaced!)
        XCTAssertEqual(reparsed.items[0].state, newState)
        XCTAssertEqual(reparsed.items[0].title, "제목", "앵커 외 나머지 본문은 그대로여야 한다")
    }

    func testReplacingAnchorLineFailsWhenExternallyChanged() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let cards = [StudyCard(title: "제목", bullets: ["불릿"], locator: .page(1),
                                quote: "발췌", unverifiedQuote: false)]
        let result = StudyNoteWriter.buildCardNote(
            cards: cards, scope: scope, noteFolder: noteFolder, title: "카드",
            now: fixedDate, makeUUID: sequentialUUIDGenerator())
        let uid = result.itemUIDs[0]

        let newState = StudyReviewState.initial(now: fixedDate)
        let replaced = StudyNoteParser.replacingAnchorLine(
            in: result.body, itemUID: uid, expectedLineText: "이미 바뀐 줄이라 가정", newState: newState)
        XCTAssertNil(replaced, "재확인 실패 시 아무것도 치환하지 않아야 한다(§3.6)")
    }

    func testReplacingAnchorLineFailsWhenUIDNotFound() {
        let replaced = StudyNoteParser.replacingAnchorLine(
            in: "아무 항목도 없는 본문", itemUID: UUID(), expectedLineText: "x",
            newState: StudyReviewState.initial())
        XCTAssertNil(replaced)
    }
}
