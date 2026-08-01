import XCTest
@testable import CmdMD

final class AppClaudeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testContextPrefersSelectionWhenPresent() {
        let r = AppState.claudeContext(selection: "선택한 문장", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "선택한 문장")
    }

    func testContextFallsBackToMarkdownWhenNoSelection() {
        let r = AppState.claudeContext(selection: "   ", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "전체 본문")
    }

    func testContextUsesOfficeMarkdownWhenNoSelectionOrMarkdown() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: "# 한글 문서")
        XCTAssertEqual(r, "# 한글 문서")
    }

    func testContextEmptyWhenNothingAvailable() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil)
        XCTAssertEqual(r, "")
    }

    func testContextUsesPdfBodyWhenNothingElseAvailable() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil, pdfBody: "PDF에서 뽑은 본문")
        XCTAssertEqual(r, "PDF에서 뽑은 본문")
    }

    func testContextPrefersOfficeMarkdownOverPdfBody() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: "오피스 본문", pdfBody: "PDF 본문")
        XCTAssertEqual(r, "오피스 본문")
    }

    func testContextPrefersPdfBodyOverMediaNote() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil, pdfBody: "PDF 본문", mediaNote: "미디어 노트")
        XCTAssertEqual(r, "PDF 본문")
    }

    func testErrorMessageMapsToolNotFound() {
        let m = AppState.claudeErrorMessage(ClaudeError.toolNotFound)
        XCTAssertTrue(m.contains("claude"))
    }

    func testErrorMessageMapsNotLoggedIn() {
        let m = AppState.claudeErrorMessage(ClaudeError.notLoggedIn)
        XCTAssertTrue(m.contains("로그인"))
    }

    func testErrorMessageMapsCreditExhausted() {
        let m = AppState.claudeErrorMessage(ClaudeError.creditExhausted)
        XCTAssertTrue(m.contains("크레딧") || m.contains("사용량"))
    }

    func testAskClaudeShortcutExistsWithDefaultBinding() {
        XCTAssertTrue(AppShortcut.allCases.contains(.askClaude))
        let b = AppShortcut.askClaude.defaultBinding
        XCTAssertEqual(b.key, "a")
        XCTAssertTrue(b.command)
        XCTAssertTrue(b.shift)
    }

    func testAskClaudeShortcutHasTitle() {
        XCTAssertFalse(AppShortcut.askClaude.title.isEmpty)
    }

    func testSelectionUsedForMarkdownKind() {
        XCTAssertEqual(AppState.claudeSelection(forKind: .markdown, selection: "선택"), "선택")
    }

    func testSelectionUsedForPdfKind() {
        // 2026-07-31: PDF도 마크다운처럼 드래그 선택을 컨텍스트로 쓴다(PDFReaderView
        // onSelectedTextChange 배선). 안 그러면 500페이지 교재를 매번 통째로 보내게 된다.
        XCTAssertEqual(AppState.claudeSelection(forKind: .pdf, selection: "선택"), "선택")
    }

    func testSelectionUsedForOfficeKind() {
        // 2026-07-31: 오피스(한글·워드·엑셀 등, kordoc 변환 프리뷰)도 드래그 선택을 컨텍스트로
        // 쓴다(MarkdownPreviewView의 selectionchange 다리). 안 그러면 긴 문서를 매번 통째로
        // 보내다 PDF와 같은 타임아웃 위험을 그대로 물려받는다.
        XCTAssertEqual(AppState.claudeSelection(forKind: .office, selection: "선택"), "선택")
    }

    func testSelectionIgnoredForImageAndMediaKinds() {
        XCTAssertEqual(AppState.claudeSelection(forKind: .image, selection: "선택"), "")
        XCTAssertEqual(AppState.claudeSelection(forKind: .media, selection: "선택"), "")
    }

    func testContextUsesMediaNoteWhenOthersEmpty() {
        let ctx = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil, mediaNote: "노트 본문")
        XCTAssertEqual(ctx, "노트 본문")
    }

    func testMediaNoteIgnoredWhenMarkdownPresent() {
        let ctx = AppState.claudeContext(selection: "", markdown: "md", officeMarkdown: nil, mediaNote: "노트")
        XCTAssertEqual(ctx, "md")
    }

    // MARK: - Task 11: 응답 저장(본문 삽입 + 노트로 저장)

    func testNoteTitleFromPromptTrimsAndCaps() {
        XCTAssertEqual(AppState.noteTitle(fromPrompt: "  이 문서를\n요약해줘  "), "이 문서를 요약해줘")
        XCTAssertEqual(AppState.noteTitle(fromPrompt: ""), "Claude 응답")
        XCTAssertEqual(AppState.noteTitle(fromPrompt: String(repeating: "가", count: 60)).count, 40)
    }

    @MainActor
    func testResetClaudeSessionClearsPromptResponseAndError() {
        // 2026-08-01: 패널의 "대화 지우기" 버튼 — 이전 질문/답변/에러를 전부 비운다.
        let app = AppState(dataDirectory: tempDir)
        app.claudePrompt = "이전 질문"
        app.claudeResponse = "이전 답변"
        app.claudeError = "이전 에러"

        app.resetClaudeSession()

        XCTAssertEqual(app.claudePrompt, "")
        XCTAssertNil(app.claudeResponse)
        XCTAssertNil(app.claudeError)
    }

    @MainActor
    func testInsertClaudeResponseAppendsToContentInPreviewMode() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "본문")
        app.viewMode = .preview
        app.claudeResponse = "응답 내용"

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "본문\n\n응답 내용\n")
    }

    @MainActor
    func testInsertClaudeResponsePostsNotificationInSourceMode() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "본문")
        app.viewMode = .source
        app.claudeResponse = "응답 내용"

        let expectation = expectation(forNotification: .insertClaudeResponse, object: nil) { note in
            (note.object as? String) == "\n\n응답 내용\n"
        }

        app.insertClaudeResponseIntoCurrentNote()

        wait(for: [expectation], timeout: 1)
        // 알림으로 위임했을 뿐, AppState가 직접 본문을 바꾸지는 않는다(실제 삽입은 Coordinator 몫).
        XCTAssertEqual(app.currentDocument?.content, "본문")
    }

    @MainActor
    func testInsertClaudeResponseAppendsToContentInLibraryMode() {
        // 라이브러리 모드에선 MarkdownTextEditor(알림 구독자)가 비마운트라
        // 알림 게시로는 아무 일도 안 일어난다 — append 폴백이어야 한다.
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "본문")
        app.mainMode = .library
        app.viewMode = .source
        app.claudeResponse = "응답 내용"

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "본문\n\n응답 내용\n")
    }

    @MainActor
    func testInsertClaudeResponseNoOpWhenNotMarkdownKind() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .office)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "원본")
        app.claudeResponse = "응답"

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "원본")
    }

    @MainActor
    func testInsertClaudeResponseNoOpWhenResponseEmpty() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "원본")
        app.claudeResponse = nil

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "원본")
    }

    @MainActor
    func testSaveClaudeResponseAsNoteSetsErrorWhenNoVault() async {
        let app = AppState(dataDirectory: tempDir)
        app.claudeResponse = "응답"

        let saved = await app.saveClaudeResponseAsNote()

        XCTAssertFalse(saved, "볼트 미설정 시 false를 반환해 호출부가 성공 피드백을 표시하지 않도록 해야 한다")
        XCTAssertEqual(app.claudeError, "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요.")
    }

    @MainActor
    func testSaveClaudeResponseAsNoteNoOpWhenResponseEmpty() async {
        let app = AppState(dataDirectory: tempDir)
        app.claudeResponse = nil

        let saved = await app.saveClaudeResponseAsNote()

        XCTAssertFalse(saved)
        XCTAssertNil(app.claudeError)
    }

    @MainActor
    func testSaveClaudeResponseAsNoteWritesFileToDefaultVault() async {
        let vaultRoot = tempDir.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let app = AppState(dataDirectory: tempDir)
        let vault = Vault(name: "테스트볼트", rootPath: vaultRoot)
        app.vaults = [vault]
        app.claudePrompt = "이 문서를 요약해줘"
        app.claudeResponse = "요약된 응답 내용"

        let saved = await app.saveClaudeResponseAsNote()

        XCTAssertTrue(saved, "정상 저장 시 true를 반환해야 호출부의 성공 피드백 게이트가 작동한다")
        XCTAssertNil(app.claudeError)
        let inboxDir = vaultRoot.appendingPathComponent("Inbox", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []
        XCTAssertEqual(files.count, 1)
        if let name = files.first {
            let content = try? String(contentsOf: inboxDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(content?.contains("요약된 응답 내용") ?? false)
            XCTAssertTrue(name.contains("이 문서를"))
        }
    }

    // MARK: - 파일 우클릭 "Claude로 요약"

    func testIsSummarizableAcceptsOfficePdfAndText() {
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.hwp")))
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.docx")))
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.txt")))
    }

    func testIsSummarizableRejectsImagesMediaAndUnknown() {
        XCTAssertFalse(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertFalse(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.zip")))
    }

    @MainActor
    func testSummarizeFileSetsPromptAndShowsPanel() {
        let app = AppState(dataDirectory: tempDir)
        let url = tempDir.appendingPathComponent("note.md")
        try? "본문".write(to: url, atomically: true, encoding: .utf8)

        app.summarizeFile(at: url)

        XCTAssertTrue(app.claudePanelVisible)
        XCTAssertTrue(app.claudeBusy)
        XCTAssertFalse(app.claudePrompt.isEmpty)
        XCTAssertNil(app.claudeError)
    }

    @MainActor
    func testSummarizeFileIgnoredWhileBusy() {
        let app = AppState(dataDirectory: tempDir)
        app.claudeBusy = true
        app.claudePanelVisible = false
        let priorPrompt = app.claudePrompt

        app.summarizeFile(at: tempDir.appendingPathComponent("x.md"))

        XCTAssertFalse(app.claudePanelVisible, "이미 다른 요청이 진행 중이면 새 요청을 겹쳐 시작하지 않는다")
        XCTAssertEqual(app.claudePrompt, priorPrompt)
    }

    // MARK: - 학습도우미 S0(2026-07-31) 프리셋 버튼

    @MainActor
    func testFillStudyCardPromptFillsPromptOnly() {
        let app = AppState(dataDirectory: tempDir)
        app.claudePrompt = ""
        app.claudeResponse = "이전 응답"
        app.claudeBusy = false

        app.fillStudyCardPrompt()

        XCTAssertTrue(app.claudePrompt.contains("정리 카드"))
        XCTAssertTrue(app.claudePrompt.contains("### [카드]"))
        XCTAssertFalse(app.claudeBusy, "프롬프트만 채우고 전송하지 않는다")
        XCTAssertEqual(app.claudeResponse, "이전 응답", "채우기만 하고 기존 응답 상태를 건드리지 않는다")
    }

    @MainActor
    func testFillStudyQuizPromptFillsPromptOnly() {
        let app = AppState(dataDirectory: tempDir)
        app.claudePrompt = ""
        app.claudeBusy = false

        app.fillStudyQuizPrompt()

        XCTAssertTrue(app.claudePrompt.contains("문제"))
        XCTAssertTrue(app.claudePrompt.contains("### [문제 1]"))
        XCTAssertFalse(app.claudeBusy, "프롬프트만 채우고 전송하지 않는다")
    }

    @MainActor
    func testFillStudyCardPromptOverwritesExistingPrompt() {
        let app = AppState(dataDirectory: tempDir)
        app.claudePrompt = "이전에 쓰던 프롬프트"

        app.fillStudyCardPrompt()

        XCTAssertNotEqual(app.claudePrompt, "이전에 쓰던 프롬프트")
    }
    // MARK: - "두 파일 비교…" (Docufinder 격차 3번)

    func testComparablePairAcceptsTwoTextFiles() throws {
        let a = tempDir.appendingPathComponent("a.md")
        let b = tempDir.appendingPathComponent("b.md")
        try "가".write(to: a, atomically: true, encoding: .utf8)
        try "나".write(to: b, atomically: true, encoding: .utf8)

        let pair = AppState.comparablePair([a, b])

        XCTAssertEqual(pair?.0, a)
        XCTAssertEqual(pair?.1, b)
    }

    func testComparablePairRejectsWrongCount() throws {
        let a = tempDir.appendingPathComponent("a.md")
        try "가".write(to: a, atomically: true, encoding: .utf8)
        XCTAssertNil(AppState.comparablePair([a]))
        XCTAssertNil(AppState.comparablePair([]))
    }

    func testComparablePairRejectsWhenOneIsDirectory() throws {
        let a = tempDir.appendingPathComponent("a.md")
        try "가".write(to: a, atomically: true, encoding: .utf8)
        let folder = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertNil(AppState.comparablePair([a, folder]))
    }

    func testComparablePairRejectsNonSummarizableExtension() throws {
        let a = tempDir.appendingPathComponent("a.md")
        let b = tempDir.appendingPathComponent("b.png")
        try "가".write(to: a, atomically: true, encoding: .utf8)
        try Data().write(to: b)

        XCTAssertNil(AppState.comparablePair([a, b]))
    }

    @MainActor
    func testRequestCompareShowsSheetAndComputesDiff() async throws {
        let app = AppState(dataDirectory: tempDir)
        let a = tempDir.appendingPathComponent("a.md")
        let b = tempDir.appendingPathComponent("b.md")
        try "한 줄\n같은 줄".write(to: a, atomically: true, encoding: .utf8)
        try "다른 줄\n같은 줄".write(to: b, atomically: true, encoding: .utf8)

        app.requestCompare(urlA: a, urlB: b)
        XCTAssertNotNil(app.compareRequest)
        XCTAssertTrue(app.compareBusy)

        // requestCompare의 Task는 async let 두 개짜리라 즉시 안 끝난다 — 짧게 양보하며 대기.
        for _ in 0..<50 where app.compareBusy {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(app.compareBusy)
        XCTAssertNil(app.compareError)
        XCTAssertTrue(app.compareDiffLines.contains(where: { $0.kind == .removed && $0.text == "한 줄" }))
        XCTAssertTrue(app.compareDiffLines.contains(where: { $0.kind == .added && $0.text == "다른 줄" }))
        XCTAssertTrue(app.compareDiffLines.contains(where: { $0.kind == .same && $0.text == "같은 줄" }))
    }

    @MainActor
    func testRequestCompareIgnoredWhileBusy() {
        let app = AppState(dataDirectory: tempDir)
        app.compareBusy = true
        let priorRequest = app.compareRequest

        app.requestCompare(urlA: tempDir.appendingPathComponent("a.md"),
                            urlB: tempDir.appendingPathComponent("b.md"))

        XCTAssertEqual(app.compareRequest?.id, priorRequest?.id)
    }
}
