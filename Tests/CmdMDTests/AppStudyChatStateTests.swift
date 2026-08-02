import XCTest
@testable import CmdMD

/// S3 넷째 조각 — `AppState+StudyChat.swift` 배선(시작→전송→중단→저장→닫기)이 임시 디렉터리
/// 격리 상태에서 정확히 동작하는지 확인한다. 예산·트리밍·접기·스트리밍 자체의 계약은
/// `ChatContextAssemblerTests`/`StudyChatServiceTests`가 이미 검증했으므로 여기선 "이어 붙임"만 본다.
@MainActor
final class AppStudyChatStateTests: XCTestCase {
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

    // MARK: - 가짜 Claude(StudyChatServiceTests 전례와 동일 계약)

    private actor ScriptedStreamClaude: ClaudeAsking {
        var chunks: [String]
        var delayNanoseconds: UInt64
        private(set) var askStreamCallCount = 0

        init(chunks: [String] = ["안녕", "하세요"], delayNanoseconds: UInt64 = 0) {
            self.chunks = chunks
            self.delayNanoseconds = delayNanoseconds
        }

        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            chunks.joined()
        }
        func askStream(prompt: String, context: String) async -> AsyncThrowingStream<String, Error> {
            askStreamCallCount += 1
            let items = chunks
            let delay = delayNanoseconds
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for item in items {
                        if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        continuation.yield(item)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func makeSource(name: String = "교재.md", content: String = "# 1장\n교재 원문 발췌 내용") -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 시작

    func testStartStudyChatWithoutScopeSetsKoreanError() {
        app.studyScopeFileURL = nil
        app.studyScopeKind = nil
        app.startStudyChat()
        XCTAssertEqual(app.studyChatError, "먼저 학습할 파일을 선택하세요.")
        XCTAssertNil(app.studyChatSession)
        XCTAssertFalse(app.showStudyChat)
    }

    func testStartStudyChatBuildsSessionWithTaggedPinnedExcerpt() async {
        let url = makeSource()
        app.studyScopeFileURL = url
        app.studyScopeKind = .markdown
        app.mainMode = .study

        app.startStudyChat()
        var tries = 0
        while app.studyChatBusy && tries < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }

        XCTAssertNotNil(app.studyChatSession)
        XCTAssertEqual(app.studyChatSession?.sourceURL, url)
        XCTAssertTrue(app.studyChatSession?.pinnedExcerpt.contains("교재 원문 발췌 내용") ?? false)
        XCTAssertTrue(app.studyChatSession?.pinnedExcerpt.contains("[[l") ?? false, "위치 태그가 붙어야 함")
        XCTAssertTrue(app.studyChatSession?.turns.isEmpty ?? false)
        XCTAssertTrue(app.showStudyChat)
        XCTAssertEqual(app.mainMode, .study, "대화 시트는 학습도우미 화면 위에 뜬다")
    }

    // MARK: - 전송

    func testSendMessageAppendsUserAndAssistantTurnsAndClearsInput() async {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "[[l1]] 발췌")
        app.studyChatService = StudyChatService(claude: ScriptedStreamClaude(chunks: ["안", "녕"]))
        app.studyChatText = "질문 있어요"

        await app.sendStudyChatMessage()

        XCTAssertEqual(app.studyChatText, "")
        XCTAssertFalse(app.studyChatBusy)
        XCTAssertNil(app.studyChatError)
        XCTAssertEqual(app.studyChatSession?.turns.count, 2)
        XCTAssertEqual(app.studyChatSession?.turns.first?.role, .user)
        XCTAssertEqual(app.studyChatSession?.turns.first?.text, "질문 있어요")
        XCTAssertEqual(app.studyChatSession?.turns.last?.role, .assistant)
        XCTAssertEqual(app.studyChatSession?.turns.last?.text, "안녕")
    }

    func testSendMessageIgnoresBlankInput() async {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "")
        app.studyChatService = StudyChatService(claude: ScriptedStreamClaude())
        app.studyChatText = "   "

        await app.sendStudyChatMessage()

        XCTAssertEqual(app.studyChatSession?.turns.count, 0)
    }

    /// cap을 극단적으로 작게 하면 `.noSend` — AI 호출 없이 되돌리고(부분 전송 없음) 입력을 복원한다.
    func testSendMessageNoSendRestoresInputWithoutMutatingTurns() async {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "발췌")
        app.studyChatService = StudyChatService(claude: ScriptedStreamClaude())
        app.settings.chatContextCap = 1
        app.studyChatText = "질문"

        await app.sendStudyChatMessage()

        XCTAssertEqual(app.studyChatSession?.turns.count, 0, "no-send면 아무 턴도 남지 않아야 함")
        XCTAssertEqual(app.studyChatText, "질문", "다시 보낼 수 있게 입력이 복원돼야 함")
        XCTAssertNotNil(app.studyChatError)
        XCTAssertFalse(app.studyChatBusy)
    }

    // MARK: - 중단(AC #19)

    func testStopStudyChatCancelsAndPreservesPartialText() async {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "")
        app.studyChatService = StudyChatService(
            claude: ScriptedStreamClaude(chunks: ["첫", "둘", "셋", "넷"], delayNanoseconds: 200_000_000))
        app.studyChatText = "질문"

        let sendTask = Task { await app.sendStudyChatMessage() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        app.stopStudyChat()
        await sendTask.value

        XCTAssertFalse(app.studyChatBusy)
        let lastText = app.studyChatSession?.turns.last?.text ?? ""
        XCTAssertTrue(lastText.hasSuffix("(중단됨)"), "부분 텍스트 뒤에 중단 표시가 붙어야 함: \(lastText)")
        XCTAssertFalse(lastText == "(중단됨)", "받은 부분 텍스트는 보존돼야 함")
    }

    // MARK: - 저장(AC #21 "화면의 원본 턴 전문을 저장한다")

    func testSaveWithoutTurnsWritesNothing() async {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "")

        await app.saveStudyChatAsNote()

        XCTAssertNotNil(app.studyChatError)
        let inbox = vaultRoot.appendingPathComponent("Inbox")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        XCTAssertTrue(files.isEmpty, "저장할 턴이 없으면 디스크 변화가 없어야 한다")
    }

    func testSaveWritesNoteWithTranscript() async {
        let url = makeSource()
        var session = StudyChatSession(sourceURL: url, pinnedExcerpt: "[[l1]] 핵심 발췌")
        session.turns = [
            StudyChatTurn(role: .user, text: "1장이 뭐야?"),
            StudyChatTurn(role: .assistant, text: "1장은 이것을 다룹니다."),
        ]
        app.studyChatSession = session

        await app.saveStudyChatAsNote()

        XCTAssertNil(app.studyChatError)
        guard let savedURL = app.studyChatSavedNoteURL else {
            return XCTFail("저장된 노트 경로가 있어야 함")
        }
        let body = try! String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(body.contains("study_kind: chat"))
        XCTAssertTrue(body.contains("### 사용자"))
        XCTAssertTrue(body.contains("1장이 뭐야?"))
        XCTAssertTrue(body.contains("### 도우미"))
        XCTAssertTrue(body.contains("1장은 이것을 다룹니다."))
        XCTAssertTrue(body.contains("핵심 발췌"))
    }

    // MARK: - 닫기(정상 종료 경로, AC #20)

    func testCloseStudyChatResetsState() {
        app.studyChatSession = StudyChatSession(sourceURL: nil, pinnedExcerpt: "x")
        app.showStudyChat = true
        app.studyChatText = "남은 글자"
        app.studyChatError = "에러"
        app.studyChatNotice = "안내"
        app.studyChatSavedNoteURL = URL(fileURLWithPath: "/tmp/x.md")

        app.closeStudyChat()

        XCTAssertFalse(app.showStudyChat)
        XCTAssertNil(app.studyChatSession)
        XCTAssertEqual(app.studyChatText, "")
        XCTAssertNil(app.studyChatError)
        XCTAssertNil(app.studyChatNotice)
        XCTAssertNil(app.studyChatSavedNoteURL)
    }
}
