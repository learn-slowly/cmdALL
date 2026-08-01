import XCTest
@testable import CmdMD

/// S1 첫 조각 — 학습도우미 자료 모양(StudyLocator/StudyItem/StudyScope/StudyChatDraft)의
/// 기본값·인코딩이 설계 문서(§3.3·§3.9·§4.7.2·§5.1·§5.2)와 어긋나지 않는지 확인한다.
/// 아직 로직(생성·파싱·저장)은 없으므로 여기서는 값 그릇 자체만 검증한다.
final class StudyModelsTests: XCTestCase {

    // MARK: - StudyLocator / StudySegment / StudyChunk

    func testStudyLocatorCasesAreDistinctAndEquatable() {
        XCTAssertEqual(StudyLocator.page(12), StudyLocator.page(12))
        XCTAssertNotEqual(StudyLocator.page(12), StudyLocator.page(13))
        XCTAssertNotEqual(StudyLocator.page(12), StudyLocator.line(12))
        XCTAssertEqual(StudyLocator.pageRange(1, 3), StudyLocator.pageRange(1, 3))
        XCTAssertEqual(StudyLocator.unknown, StudyLocator.unknown)
    }

    func testStudyChunkCarriesCoveredLocatorsForCitationCheck() {
        let chunk = StudyChunk(
            body: "본문",
            coveredLocators: [.page(12), .page(13)],
            charCount: 2
        )
        XCTAssertTrue(chunk.coveredLocators.contains(.page(12)))
        XCTAssertFalse(chunk.coveredLocators.contains(.page(99)))
        XCTAssertEqual(chunk.charCount, 2)
    }

    // MARK: - StudyItem (카드·문제·복습 상태)

    func testStudyItemKindRawValuesMatchFrontmatterVocabulary() {
        // §3.5: frontmatter `study_kind`에 그대로 적히는 값이라 대소문자·철자가 고정이어야 한다.
        XCTAssertEqual(StudyItemKind.card.rawValue, "card")
        XCTAssertEqual(StudyItemKind.question.rawValue, "question")
    }

    func testStudyCardHoldsUnverifiedQuoteFlagWithoutDiscardingIt() {
        // §O4: 발췌 불일치는 폐기 대상이 아니라 표시만 하는 대상 — 값이 살아있어야 한다.
        let card = StudyCard(
            title: "제목",
            bullets: ["핵심 1", "핵심 2"],
            locator: .page(12),
            quote: "교재 원문 발췌",
            unverifiedQuote: true
        )
        XCTAssertEqual(card.bullets.count, 2)
        XCTAssertTrue(card.unverifiedQuote)
    }

    func testStudyQuestionAllowsEmptyOptionsForNonMcqTypes() {
        // §O2: 보기 3~5개는 type이 "mcq"일 때만 필수 — 그 외 타입은 옵션 없이도 유효한 그릇이어야 한다.
        let shortAnswer = StudyQuestion(
            title: "요지",
            type: "short",
            prompt: "질문",
            options: [],
            answer: "정답",
            explanation: "해설",
            locator: .line(345),
            quote: "발췌",
            unverifiedQuote: false
        )
        XCTAssertTrue(shortAnswer.options.isEmpty)

        let mcq = StudyQuestion(
            title: "요지",
            type: "mcq",
            prompt: "질문",
            options: ["A", "B", "C"],
            answer: "2",
            explanation: "해설",
            locator: .page(12),
            quote: "발췌",
            unverifiedQuote: false
        )
        XCTAssertEqual(mcq.options.count, 3)
    }

    func testStudyReviewStateInitialIsWithinSchedulerBounds() {
        // §3.9: ease 허용 범위 [1.30, 2.80]. 새 항목은 아직 한 번도 안 봤으니 reps/lapses 0, interval 0.
        let now = Date()
        let state = StudyReviewState.initial(now: now)
        XCTAssertEqual(state.due, now)
        XCTAssertEqual(state.interval, 0)
        XCTAssertEqual(state.reps, 0)
        XCTAssertEqual(state.lapses, 0)
        XCTAssertGreaterThanOrEqual(state.ease, 1.30)
        XCTAssertLessThanOrEqual(state.ease, 2.80)
    }

    // MARK: - StudyScope

    func testStudyScopeRangeVariantsMatchDocumentKindGranularity() {
        // §5.2: PDF=쪽 범위, 마크다운/텍스트=줄 범위, 오피스/이미지=위치 단위 없음(전체 파일만).
        let pdfScope = StudyScope(
            fileURL: URL(fileURLWithPath: "/tmp/책.pdf"),
            kind: .pdf,
            range: .pageRange(10, 20)
        )
        let mdScope = StudyScope(
            fileURL: URL(fileURLWithPath: "/tmp/노트.md"),
            kind: .markdown,
            range: .lineRange(1, 200)
        )
        let officeScope = StudyScope(
            fileURL: URL(fileURLWithPath: "/tmp/보고서.docx"),
            kind: .office,
            range: .wholeFile
        )

        guard case .pageRange(let start, let end) = pdfScope.range else {
            return XCTFail("PDF 범위는 pageRange여야 한다")
        }
        XCTAssertEqual(start, 10)
        XCTAssertEqual(end, 20)

        guard case .lineRange = mdScope.range else {
            return XCTFail("마크다운 범위는 lineRange여야 한다")
        }
        XCTAssertEqual(officeScope.range, .wholeFile)
    }

    // MARK: - StudyChatDraft (크래시 대비 임시 초안, §4.7.2)

    func testStudyChatDraftRoundTripsThroughJSONPreservingTurnOrder() {
        let draft = StudyChatDraft(
            schemaVersion: StudyChatDraft.currentSchemaVersion,
            sessionId: UUID(),
            sourcePath: "/tmp/교재.pdf",
            sourceDisplayName: "교재.pdf",
            pinnedExcerpt: "핀 발췌",
            turns: [
                StudyChatDraftTurn(role: "user", text: "첫 질문", truncated: false),
                StudyChatDraftTurn(role: "assistant", text: "첫 답변", truncated: false),
                StudyChatDraftTurn(role: "user", text: "두 번째 질문", truncated: true),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appBuild: "0.9.500"
        )

        let data = try! JSONEncoder().encode(draft)
        let decoded = try! JSONDecoder().decode(StudyChatDraft.self, from: data)

        XCTAssertEqual(decoded, draft)
        XCTAssertEqual(decoded.turns.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(decoded.turns.last?.truncated, true)
    }

    func testStudyChatDraftAllowsNilSourceWhenFileIsGone() {
        // §4.7.5 4번: 원본 파일 경로가 사라졌을 수 있다 — optional이라 nil 인코딩·디코딩이 크래시 없이 돼야 한다.
        let draft = StudyChatDraft(
            schemaVersion: 1,
            sessionId: UUID(),
            sourcePath: nil,
            sourceDisplayName: nil,
            pinnedExcerpt: "",
            turns: [StudyChatDraftTurn(role: "user", text: "질문", truncated: false)],
            updatedAt: Date(),
            appBuild: "0.9.500"
        )

        let data = try! JSONEncoder().encode(draft)
        let decoded = try! JSONDecoder().decode(StudyChatDraft.self, from: data)

        XCTAssertNil(decoded.sourcePath)
        XCTAssertNil(decoded.sourceDisplayName)
    }

    func testStudyChatDraftCurrentSchemaVersionIsStable() {
        // 이 값이 바뀌면 기존 초안이 전부 폐기(§4.7.5 2번) 대상이 되므로, 의도치 않은 변경을 잡아낸다.
        XCTAssertEqual(StudyChatDraft.currentSchemaVersion, 1)
    }
}
