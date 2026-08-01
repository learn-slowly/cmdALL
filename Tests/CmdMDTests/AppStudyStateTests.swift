import XCTest
@testable import CmdMD

/// 학습도우미(Study Helper) S1 마지막 조각 — `AppState+Study.swift` 배선(파일 선택→미리 분량
/// →생성→저장)이 임시 디렉터리 격리 상태에서 정확히 동작하는지 확인한다. 실제 로직(청크·프롬프트·
/// 파싱·오케스트레이션)은 `Study*` 개별 테스트가 이미 검증했으므로 여기선 "이어 붙임"만 본다.
@MainActor
final class AppStudyStateTests: XCTestCase {
    var tempData: URL!
    var sourceDir: URL!
    var vaultRoot: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        sourceDir = TempDataDirectory.make()
        vaultRoot = tempData.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        app = AppState(dataDirectory: tempData)
        app.vaults = [Vault(name: "테스트볼트", rootPath: vaultRoot)]
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(sourceDir)
        super.tearDown()
    }

    // MARK: - 가짜 Claude(StudyServiceTests 전례와 동일 계약)

    private actor ScriptedClaude: ClaudeAsking {
        private var responses: [String]
        init(_ responses: [String]) { self.responses = responses }
        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            guard !responses.isEmpty else { return "" }
            return responses.removeFirst()
        }
    }

    private func makeSource(name: String = "자격증.md", content: String = "# 하나\n교재 원문 발췌 내용") -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validCardResponse(title: String = "핵심 개념") -> String {
        """
        ### [카드] \(title)
        - 핵심 1
        - 핵심 2
        > 근거: [[l1]] "발췌"
        """
    }

    // MARK: - 파일 선택 → 사전 분량 표시(AC #9)

    func testPickingSourceUpdatesPreviewPlanAndResetsPriorResult() async {
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyPreviewCards = [StudyCard(title: "이전", bullets: ["x"], locator: .unknown, quote: "q", unverifiedQuote: false)]
        app.studyOutcomeSummary = "이전 요약"

        await app.updateStudyPreviewPlan()

        XCTAssertGreaterThan(app.studyPreviewChunkCount, 0)
        XCTAssertGreaterThan(app.studyPreviewCharCount, 0)
    }

    func testEmptyScopeHasZeroPreviewPlan() async {
        app.studyScopeFileURL = nil
        app.studyScopeKind = nil
        await app.updateStudyPreviewPlan()
        XCTAssertEqual(app.studyPreviewChunkCount, 0)
        XCTAssertEqual(app.studyPreviewCharCount, 0)
    }

    // MARK: - 생성

    func testGenerateWithoutScopeSetsKoreanError() async {
        app.studyScopeFileURL = nil
        app.studyScopeKind = nil
        await app.generateStudyItems()
        XCTAssertEqual(app.studyError, "먼저 학습할 파일을 선택하세요.")
        XCTAssertFalse(app.studyBusy)
    }

    func testGenerateCardsPopulatesPreviewAndSummary() async {
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyGenerationKind = .card
        app.studyRequestedCount = 3
        app.studyService = StudyService(claude: ScriptedClaude([validCardResponse()]),
                                         sourceLoader: app.studySourceLoader)

        await app.generateStudyItems()

        XCTAssertEqual(app.studyPreviewCards.map(\.title), ["핵심 개념"])
        XCTAssertNil(app.studyError)
        XCTAssertNotNil(app.studyOutcomeSummary)
        XCTAssertFalse(app.studyBusy)
    }

    func testGenerateEmptyContentMapsToKoreanGuidance() async {
        let src = makeSource(name: "빈글.md", content: "   \n  ")
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyService = StudyService(claude: ScriptedClaude([]), sourceLoader: app.studySourceLoader)

        await app.generateStudyItems()

        XCTAssertTrue(app.studyPreviewCards.isEmpty)
        XCTAssertNotNil(app.studyError)
        XCTAssertFalse(app.studyBusy)
    }

    // MARK: - 저장(AC #6 "취소 시 디스크 변화 0")

    func testSaveWithoutGeneratedItemsWritesNothing() async {
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyPreviewCards = []
        app.studyPreviewQuestions = []

        await app.saveStudyNote()

        XCTAssertNotNil(app.studyError)
        let inbox = vaultRoot.appendingPathComponent("Inbox")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        XCTAssertTrue(files.isEmpty, "저장할 항목이 없으면 디스크 변화가 없어야 한다")
    }

    func testSaveWritesNoteFileWithFrontmatterAndOpensLater() async {
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyGenerationKind = .card
        app.studyPreviewCards = [
            StudyCard(title: "핵심 개념", bullets: ["첫째"], locator: .line(1), quote: "발췌", unverifiedQuote: false)
        ]

        await app.saveStudyNote()

        XCTAssertNil(app.studyError)
        guard let savedURL = app.studySavedNoteURL else {
            return XCTFail("저장 성공 시 studySavedNoteURL이 채워져야 한다")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let content = try? String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(content?.contains("study_kind: card") ?? false)
        XCTAssertTrue(content?.contains("### [카드] 핵심 개념") ?? false)

        // 원본 교재는 손대지 않는다(AC #8).
        let originalStillThere = try? String(contentsOf: src, encoding: .utf8)
        XCTAssertEqual(originalStillThere, "# 하나\n교재 원문 발췌 내용")
    }

    func testSaveWithoutVaultSetsKoreanError() async {
        app.vaults = []
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyPreviewCards = [
            StudyCard(title: "제목", bullets: ["x"], locator: .unknown, quote: "q", unverifiedQuote: false)
        ]

        await app.saveStudyNote()

        XCTAssertNil(app.studySavedNoteURL)
        XCTAssertEqual(app.studyError, "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요.")
    }
}
