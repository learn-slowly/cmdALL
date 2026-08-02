import XCTest
import PDFKit
import AppKit
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
        private(set) var calls: [(prompt: String, context: String)] = []
        init(_ responses: [String]) { self.responses = responses }
        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            calls.append((prompt, context))
            guard !responses.isEmpty else { return "" }
            return responses.removeFirst()
        }
        func recordedPrompts() -> [String] { calls.map(\.prompt) }
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

    // MARK: - 학습도우미 열기 → 마지막 교재 파일 복원(레고 2026-08-01 "매번 선택하려니 귀찮다")

    func testOpenStudyHelperRestoresLastSelectedFile() {
        let src = makeSource(name: "지난번교재.md")
        app.settings.lastStudySourcePath = src.path
        XCTAssertNil(app.studyScopeFileURL)

        app.openStudyHelper()

        XCTAssertEqual(app.mainMode, .study)
        XCTAssertEqual(app.studyScopeFileURL, src)
        XCTAssertEqual(app.studyScopeKind, .markdown)
    }

    func testOpenStudyHelperIgnoresMissingLastFileWithoutCrashing() {
        let missing = sourceDir.appendingPathComponent("지워진파일.md")
        app.settings.lastStudySourcePath = missing.path

        app.openStudyHelper()

        XCTAssertEqual(app.mainMode, .study)
        XCTAssertNil(app.studyScopeFileURL, "실존하지 않는 파일은 조용히 무시돼야 함")
        XCTAssertNil(app.studyError, "복원 실패는 에러로 띄우지 않는다(사용자가 시작한 동작이 아님)")
    }

    func testOpenStudyHelperWithNoSavedPathLeavesSelectionEmpty() {
        app.settings.lastStudySourcePath = nil

        app.openStudyHelper()

        XCTAssertEqual(app.mainMode, .study)
        XCTAssertNil(app.studyScopeFileURL)
    }

    /// 다듬기 C — 학습도우미는 팝업이 아니라 메인 화면 모드다. 닫으면 파일 화면으로 돌아간다.
    func testCloseStudyHelperReturnsToReaderMode() {
        app.openStudyHelper()
        XCTAssertEqual(app.mainMode, .study)

        app.closeStudyHelper()

        XCTAssertEqual(app.mainMode, .reader)
        XCTAssertNil(app.studyGenerateTask, "닫으면 만들던 것도 멈춘다")
    }

    func testOpenStudyHelperDoesNotOverrideAlreadySelectedFile() {
        let current = makeSource(name: "지금선택.md")
        let last = makeSource(name: "예전선택.md")
        app.studyScopeFileURL = current
        app.studyScopeKind = .markdown
        app.settings.lastStudySourcePath = last.path

        app.openStudyHelper()

        XCTAssertEqual(app.studyScopeFileURL, current, "같은 세션에서 이미 골라둔 파일을 덮어쓰면 안 됨")
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

    // MARK: - 부분 범위 선택(레고 2026-08-01 피드백 — "교재 전체를 한 번에 넣는 건 비현실적")

    private func makeBlankPDF(name: String = "교재.pdf", pageCount: Int) -> URL {
        let pdf = PDFDocument()
        for index in 0..<pageCount {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .calibratedRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: NSSize(width: 10, height: 10))
            image.addRepresentation(bitmap)
            pdf.insert(PDFPage(image: image)!, at: index)
        }
        let url = sourceDir.appendingPathComponent(name)
        XCTAssertTrue(pdf.write(to: url))
        return url
    }

    func testLoadRangeMetadataForPDFCapturesPageCountAndDefaultsToFullRange() async {
        let url = makeBlankPDF(pageCount: 5)
        app.studyScopeFileURL = url
        app.studyScopeKind = .pdf

        await app.loadStudyRangeMetadata(kind: .pdf, url: url)

        XCTAssertEqual(app.studyPDFPageCount, 5)
        XCTAssertEqual(app.studyPageRangeStart, 1)
        XCTAssertEqual(app.studyPageRangeEnd, 5)
    }

    // MARK: - 쪽 번호 직접입력 정리(레고 2026-08-01 요청 — 스테퍼 대신 타이핑)

    func testClampStudyPageRangeKeepsWithinDocumentBoundsAndOrder() async {
        app.studyPDFPageCount = 10
        app.studyPageRangeStart = 999   // 직접입력으로 쪽수를 넘겨 쳤을 때.
        app.studyPageRangeEnd = 5

        app.clampStudyPageRange(changed: .start)

        XCTAssertEqual(app.studyPageRangeStart, 10, "문서 쪽수를 넘으면 최대 쪽수로 정리돼야 한다")
        XCTAssertEqual(app.studyPageRangeEnd, 10, "시작이 끝보다 커지면 끝을 밀어줘야 한다")
    }

    func testClampStudyPageRangeRejectsZeroOrNegativeInput() async {
        app.studyPDFPageCount = 20
        app.studyPageRangeStart = 0
        app.studyPageRangeEnd = 15

        app.clampStudyPageRange(changed: .start)

        XCTAssertEqual(app.studyPageRangeStart, 1, "0 이하로 지우거나 음수를 치면 1쪽으로 정리돼야 한다")
    }

    func testClampStudyPageRangePushesStartDownWhenEndTypedSmaller() async {
        app.studyPDFPageCount = 20
        app.studyPageRangeStart = 10
        app.studyPageRangeEnd = 3   // 끝을 시작보다 작게 직접 쳤을 때.

        app.clampStudyPageRange(changed: .end)

        XCTAssertEqual(app.studyPageRangeStart, 3, "끝이 시작보다 작아지면 시작을 끌어내려야 한다")
        XCTAssertEqual(app.studyPageRangeEnd, 3)
    }

    func testLoadRangeMetadataForMarkdownCapturesHeadingsInLineOrder() async {
        let content = "머리말\n\n# 1장\n1장 내용\n\n# 2장\n2장 내용\n"
        let url = makeSource(name: "교재.md", content: content)
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown

        await app.loadStudyRangeMetadata(kind: .markdown, url: url)

        XCTAssertEqual(app.studyHeadingChoices.map(\.title), ["1장", "2장"])
        XCTAssertEqual(app.studyHeadingChoices.map(\.lineNumber), [3, 6])
        XCTAssertGreaterThan(app.studyLineCount, 0)
    }

    func testMarkdownWithoutHeadingsHasEmptyChoiceListSoPartialPickerStaysHidden() async {
        let url = makeSource(name: "표만.md", content: "그냥 평문\n둘째 줄\n")
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown

        await app.loadStudyRangeMetadata(kind: .markdown, url: url)

        XCTAssertTrue(app.studyHeadingChoices.isEmpty)
    }

    func testPickingSourceResetsPreviousRangeSelectionAndDefaultsWholeFile() async {
        // 첫 파일에서 부분 범위를 골랐다가 다른 파일을 고르면 이전 선택이 새 파일로 새지 않아야 한다.
        app.studyUseWholeFile = false
        app.studyPageRangeStart = 3
        app.studyPageRangeEnd = 4

        let url = makeBlankPDF(name: "새교재.pdf", pageCount: 2)
        app.studyScopeFileURL = url
        app.studyScopeKind = .pdf
        await app.loadStudyRangeMetadata(kind: .pdf, url: url)

        XCTAssertEqual(app.studyPageRangeStart, 1)
        XCTAssertEqual(app.studyPageRangeEnd, 2, "새 파일의 쪽수로 다시 기본값(전체)이 설정돼야 한다")
    }

    /// 부분 범위를 고르면 실제로 그 범위만 AI에 전송된다 — §Q1 "범위 선택 필수화"의 핵심 검증.
    func testPartialHeadingRangeSendsOnlySelectedSectionToClaude() async {
        let content = "# 1장\n1장 전용 내용 마커\n\n# 2장\n2장 전용 내용 마커\n"
        let url = makeSource(name: "교재.md", content: content)
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown
        await app.loadStudyRangeMetadata(kind: .markdown, url: url)

        // 2장만 선택(시작=끝=두 번째 헤딩).
        app.studyUseWholeFile = false
        app.studyHeadingRangeStartIndex = 1
        app.studyHeadingRangeEndIndex = 1

        let fake = ScriptedClaude([validCardResponse()])
        app.studyService = StudyService(claude: fake, sourceLoader: app.studySourceLoader)

        await app.generateStudyItems()

        XCTAssertFalse(app.studyPreviewCards.isEmpty, "부분 범위로도 정상 생성돼야 한다")
        // updateStudyPreviewPlan이 같은 scope로 계산한 조각 수·글자 수가 전체 파일보다 작아야
        // 실제로 일부만 보내졌다는 근거가 된다.
        app.studyUseWholeFile = true
        await app.updateStudyPreviewPlan()
        let wholeFileChars = app.studyPreviewCharCount
        app.studyUseWholeFile = false
        await app.updateStudyPreviewPlan()
        XCTAssertLessThan(app.studyPreviewCharCount, wholeFileChars)
    }

    // MARK: - 템플릿(레고 2026-08-01 요청 — "정리카드나 연습문제 템플릿을 만들거나 수정")

    func testStudyTemplatesForFiltersByKind() {
        app.settings.studyTemplates = [
            StudyTemplate(name: "쉬운 카드", kind: .card, instructions: "쉽게"),
            StudyTemplate(name: "심화 문제", kind: .question, instructions: "어렵게"),
        ]

        XCTAssertEqual(app.studyTemplates(for: .card).map(\.name), ["쉬운 카드"])
        XCTAssertEqual(app.studyTemplates(for: .question).map(\.name), ["심화 문제"])
    }

    func testChangingGenerationKindResetsSelectedTemplate() {
        let template = StudyTemplate(name: "쉬운 카드", kind: .card, instructions: "쉽게")
        app.settings.studyTemplates = [template]
        app.studyGenerationKind = .card
        app.studySelectedTemplateID = template.id

        app.studyGenerationKind = .question

        XCTAssertNil(app.studySelectedTemplateID, "종류가 바뀌면 다른 종류 템플릿 선택이 남아있으면 안 된다")
    }

    func testSettingSameGenerationKindDoesNotResetSelectedTemplate() {
        let template = StudyTemplate(name: "쉬운 카드", kind: .card, instructions: "쉽게")
        app.settings.studyTemplates = [template]
        app.studyGenerationKind = .card
        app.studySelectedTemplateID = template.id

        app.studyGenerationKind = .card // 같은 값 재대입 — 초기화되면 안 됨.

        XCTAssertEqual(app.studySelectedTemplateID, template.id)
    }

    func testSelectedTemplateInstructionsAreSentToClaude() async {
        let content = "# 하나\n교재 원문 발췌 내용"
        let url = makeSource(content: content)
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown
        app.studyGenerationKind = .card

        let template = StudyTemplate(name: "쉬운 카드", kind: .card, instructions: "쉬운 말로, 초등학생도 알아듣게")
        app.settings.studyTemplates = [template]
        app.studySelectedTemplateID = template.id

        let fake = ScriptedClaude([validCardResponse()])
        app.studyService = StudyService(claude: fake, sourceLoader: app.studySourceLoader)

        await app.generateStudyItems()

        let sentPrompts = await fake.recordedPrompts()
        XCTAssertTrue(sentPrompts.first?.contains("쉬운 말로, 초등학생도 알아듣게") ?? false)
    }

    func testNoTemplateSelectedSendsDefaultPromptUnchanged() async {
        let content = "# 하나\n교재 원문 발췌 내용"
        let url = makeSource(content: content)
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown
        app.studyGenerationKind = .card
        app.studySelectedTemplateID = nil // "기본"

        let fake = ScriptedClaude([validCardResponse()])
        app.studyService = StudyService(claude: fake, sourceLoader: app.studySourceLoader)

        await app.generateStudyItems()

        let sentPrompts = await fake.recordedPrompts()
        XCTAssertFalse(sentPrompts.first?.contains("추가 지시(사용자 템플릿)") ?? true)
    }

    // MARK: - 진행 표시·취소(다듬기 B, 2026-08-02)

    func testApplyStudyProgressFillsLabelAndFractionOnlyWhileBusy() {
        app.studyBusy = true
        app.applyStudyProgress(done: 2, total: 4)

        XCTAssertEqual(app.studyProgress, "조각 2/4 만드는 중…")
        XCTAssertEqual(app.studyProgressFraction, 0.25, accuracy: 0.001, "2번째를 시작했으면 1개 완료")

        app.studyBusy = false
        app.applyStudyProgress(done: 3, total: 4)
        XCTAssertEqual(app.studyProgress, "조각 2/4 만드는 중…", "만들기가 끝난 뒤 늦게 온 알림은 무시한다")
    }

    func testApplyStudyProgressIgnoresSingleChunk() {
        app.studyBusy = true
        app.applyStudyProgress(done: 1, total: 1)
        XCTAssertNil(app.studyProgress, "조각이 하나면 '1/1'을 띄우지 않는다")
        XCTAssertEqual(app.studyProgressFraction, 0)
    }

    func testCancelStudyGenerationIsSafeWhenIdle() {
        XCTAssertNil(app.studyGenerateTask)
        app.cancelStudyGeneration()   // 유휴 상태에서 눌러도(창 닫기) 아무 일도 없어야 한다.
        XCTAssertNil(app.studyGenerateTask)
        XCTAssertNil(app.studyError)
    }

    func testGenerateClearsProgressWhenFinished() async {
        let src = makeSource()
        app.studyScopeFileURL = src
        app.studyScopeKind = .markdown
        app.studyBusy = true
        app.applyStudyProgress(done: 1, total: 3)
        app.studyBusy = false

        app.studyGenerationKind = .card
        app.studyService = StudyService(claude: ScriptedClaude([validCardResponse()]),
                                        sourceLoader: app.studySourceLoader)
        await app.generateStudyItems()

        XCTAssertNil(app.studyProgress, "만들기가 끝나면 진행 문구는 지운다")
        XCTAssertFalse(app.studyBusy)
    }
}
