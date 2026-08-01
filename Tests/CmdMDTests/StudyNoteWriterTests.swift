import XCTest
@testable import CmdMD

/// S1 일곱째 조각 — `StudyNoteWriter`가 §3.3(앵커 문법)·§3.4(항목 필수 필드)·§3.5(frontmatter 키)를
/// 정확히 지키는지, 그리고 §O6이 발급을 위임한 `item_uid`가 항목마다 유일한지 확인한다.
/// 순수 함수라 디스크에 아무것도 안 쓴다(AC #6은 다음 조각의 몫 — 여기선 문자열만 검증).
final class StudyNoteWriterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000) // 결정적 테스트용 고정 시각.
    private let noteFolder = URL(fileURLWithPath: "/Users/lego/vault/study")

    private func makeSource(_ path: String = "/Users/lego/vault/study/자격증.pdf") -> URL {
        URL(fileURLWithPath: path)
    }

    private func makeCard(title: String = "핵심 개념", locator: StudyLocator = .page(12)) -> StudyCard {
        StudyCard(title: title, bullets: ["첫째", "둘째"], locator: locator,
                  quote: "발췌", unverifiedQuote: false)
    }

    private func makeQuestion(title: String = "문항", type: String = "mcq",
                               options: [String] = ["A", "B", "C"], locator: StudyLocator = .line(345)) -> StudyQuestion {
        StudyQuestion(title: title, type: type, prompt: "질문", options: options,
                      answer: "1", explanation: "설명", locator: locator,
                      quote: "발췌", unverifiedQuote: false)
    }

    /// 순차 UUID를 돌려주는 결정적 생성기(테스트 재현성) — 첫 호출=note id, 이후=item uid 순서.
    private func sequentialUUIDGenerator() -> () -> UUID {
        var counter = 0
        return {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        }
    }

    // MARK: - §3.5 frontmatter 키(정확한 순서)

    func testCardNoteFrontmatterHasKeysInSpecOrder() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard()], scope: scope, noteFolder: noteFolder, title: "자격증 카드",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        let frontmatterLines = result.body
            .components(separatedBy: "\n---\n").first!
            .components(separatedBy: "\n").filter { $0.hasPrefix("study_") }
        let keys = frontmatterLines.map { $0.components(separatedBy: ":").first! }
        XCTAssertEqual(keys, ["study_id", "study_kind", "study_source", "study_source_kind",
                               "study_created", "study_items", "study_due"])
    }

    func testCardNoteFrontmatterValues() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard(), makeCard(title: "둘째 카드")], scope: scope, noteFolder: noteFolder,
            title: "자격증 카드", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("study_kind: card"))
        XCTAssertTrue(result.body.contains("study_source_kind: pdf"))
        XCTAssertTrue(result.body.contains("study_items: 2"))
        XCTAssertTrue(result.body.contains("study_id: 00000000-0000-0000-0000-000000000001"),
                      "study_id는 첫 UUID 발급분이어야 한다(카드 uid보다 먼저)")
    }

    func testQuestionNoteFrontmatterKindIsQuestion() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildQuestionNote(
            questions: [makeQuestion()], scope: scope, noteFolder: noteFolder, title: "자격증 문제",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("study_kind: question"))
    }

    // MARK: - §3.3 앵커 문법

    func testAnchorLineHasExactFieldOrderAndFormat() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard(locator: .page(12))], scope: scope, noteFolder: noteFolder,
            title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        let anchorLine = result.body.components(separatedBy: "\n").first { $0.hasPrefix("<!-- study ") }
        XCTAssertNotNil(anchorLine)
        let pattern = #"^<!-- study item=[0-9a-fA-F-]{36} src=\S+ loc=p12 due=\d{4}-\d{2}-\d{2} ivl=0 ease=2\.50 reps=0 lapses=0 -->$"#
        XCTAssertNotNil(anchorLine?.range(of: pattern, options: .regularExpression),
                        "실제: \(anchorLine ?? "nil")")
    }

    func testAnchorLocFormatsForEachLocatorKind() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let cases: [(StudyLocator, String)] = [
            (.page(12), "loc=p12"), (.pageRange(3, 5), "loc=p3-5"),
            (.line(345), "loc=l345"), (.unknown, "loc=- "),
        ]
        for (locator, expectedFragment) in cases {
            let result = StudyNoteWriter.buildCardNote(
                cards: [makeCard(locator: locator)], scope: scope, noteFolder: noteFolder,
                title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
            )
            XCTAssertTrue(result.body.contains(expectedFragment), "\(locator) → \(expectedFragment) 없음")
        }
    }

    func testItemUIDsAreUniqueAndCountMatchesCards() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let cards = [makeCard(title: "A"), makeCard(title: "B"), makeCard(title: "C")]
        let result = StudyNoteWriter.buildCardNote(
            cards: cards, scope: scope, noteFolder: noteFolder, title: "제목",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertEqual(result.itemUIDs.count, 3)
        XCTAssertEqual(Set(result.itemUIDs).count, 3, "항목마다 유일한 uid여야 한다")
    }

    // MARK: - §3.4 항목 본문(카드·문제)

    func testCardBlockHeadingBulletsAndEvidenceLine() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard(title: "핵심 개념", locator: .page(12))], scope: scope, noteFolder: noteFolder,
            title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("### [카드] 핵심 개념"))
        XCTAssertTrue(result.body.contains("- 첫째"))
        XCTAssertTrue(result.body.contains("- 둘째"))
        XCTAssertTrue(result.body.contains("> 근거: [[p12]] \"발췌\""))
    }

    func testQuestionBlockIncludesOptionsWhenPresent() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildQuestionNote(
            questions: [makeQuestion(options: ["보기A", "보기B", "보기C"])], scope: scope, noteFolder: noteFolder,
            title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("### [문제 1] 문항"))
        XCTAssertTrue(result.body.contains("type: mcq"))
        XCTAssertTrue(result.body.contains("Q: 질문"))
        XCTAssertTrue(result.body.contains("1) 보기A"))
        XCTAssertTrue(result.body.contains("2) 보기B"))
        XCTAssertTrue(result.body.contains("3) 보기C"))
        XCTAssertTrue(result.body.contains("A: 1"))
        XCTAssertTrue(result.body.contains("해설: 설명"))
    }

    func testQuestionBlockOmitsOptionsWhenEmpty() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildQuestionNote(
            questions: [makeQuestion(type: "단답", options: [])], scope: scope, noteFolder: noteFolder,
            title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertFalse(result.body.contains("1) "))
        XCTAssertTrue(result.body.contains("type: 단답"))
    }

    func testQuestionNumberingIsSequential() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildQuestionNote(
            questions: [makeQuestion(title: "하나"), makeQuestion(title: "둘")], scope: scope,
            noteFolder: noteFolder, title: "제목", now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("### [문제 1] 하나"))
        XCTAssertTrue(result.body.contains("### [문제 2] 둘"))
    }

    // MARK: - 제목·본문 뼈대

    func testTitleRendersAsTopLevelHeadingAfterFrontmatter() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard()], scope: scope, noteFolder: noteFolder, title: "자격증 카드",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertTrue(result.body.contains("---\n\n# 자격증 카드\n\n"))
    }

    // MARK: - §3.3 "percent-encoded-relpath"

    func testRelativePathClimbsToCommonAncestorWithDotDot() {
        let rel = StudyNoteWriter.relativePath(
            from: URL(fileURLWithPath: "/Users/lego/vault/study"),
            to: URL(fileURLWithPath: "/Users/lego/교재/자격증.pdf")
        )
        // vault/study → 공통 조상 /Users/lego 까지 2단 위로, 그다음 교재/자격증.pdf(퍼센트 인코딩).
        XCTAssertTrue(rel.hasPrefix("../../"), "실제: \(rel)")
        XCTAssertFalse(rel.contains("교재"), "한글은 percent-encoding 돼야 한다")
        let decoded = rel.removingPercentEncoding
        XCTAssertEqual(decoded, "../../교재/자격증.pdf")
    }

    func testRelativePathWithNoAncestorClimbWhenSourceUnderNoteFolder() {
        let rel = StudyNoteWriter.relativePath(
            from: URL(fileURLWithPath: "/Users/lego/vault"),
            to: URL(fileURLWithPath: "/Users/lego/vault/sources/자격증.pdf")
        )
        XCTAssertFalse(rel.hasPrefix(".."))
        XCTAssertEqual(rel.removingPercentEncoding, "sources/자격증.pdf")
    }

    // MARK: - §3.9 초기값(새 항목은 오늘 시작)

    func testStudyDueMatchesCreatedDayForFreshItems() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result = StudyNoteWriter.buildCardNote(
            cards: [makeCard()], scope: scope, noteFolder: noteFolder, title: "제목",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        let expectedDay = dayFormatter.string(from: fixedDate)
        XCTAssertTrue(result.body.contains("study_due: \(expectedDay)"))
        XCTAssertTrue(result.body.contains("due=\(expectedDay)"), "앵커의 due도 오늘이어야 한다")
    }

    // MARK: - 결정성

    func testSameInputProducesSameOutputWithSameUUIDGenerator() {
        let scope = StudyScope(fileURL: makeSource(), kind: .pdf, range: .wholeFile)
        let result1 = StudyNoteWriter.buildCardNote(
            cards: [makeCard()], scope: scope, noteFolder: noteFolder, title: "제목",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        let result2 = StudyNoteWriter.buildCardNote(
            cards: [makeCard()], scope: scope, noteFolder: noteFolder, title: "제목",
            now: fixedDate, makeUUID: sequentialUUIDGenerator()
        )
        XCTAssertEqual(result1.body, result2.body)
        XCTAssertEqual(result1.itemUIDs, result2.itemUIDs)
    }
}
