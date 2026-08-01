import XCTest
@testable import CmdMD

/// "문서에서 할일 찾기" — `AppState+TaskFinder.swift` 배선(진입점→탐지→선택→Todoist 전송)이
/// 임시 디렉터리 격리 상태에서 정확히 동작하는지 확인한다. 탐지 로직(`TaskFinderService`)·
/// 전송 로직(`TodoistService`)은 각자 전용 테스트가 이미 검증했으므로 여기선 "이어 붙임"만 본다.
@MainActor
final class AppTaskFinderStateTests: XCTestCase {
    var tempData: URL!
    var sourceDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        sourceDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(sourceDir)
        super.tearDown()
    }

    // MARK: - 가짜 Claude·Todoist(각 서비스 전용 테스트와 동일 계약)

    private actor ScriptedClaude: ClaudeAsking {
        private let response: String
        init(_ response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            try await ask(prompt: prompt, context: context, timeout: -1)
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String { response }
    }

    private actor FakeTransport: TodoistTransport {
        private(set) var sentBodies: [[String: Any]] = []
        private let statusCode: Int
        init(statusCode: Int = 200) { self.statusCode = statusCode }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                sentBodies.append(json)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            let path = request.url!.path
            if path.hasSuffix("projects") {
                let json = #"[{"id":"1","name":"Inbox","is_inbox_project":true},{"id":"2","name":"업무","is_inbox_project":false}]"#
                return (json.data(using: .utf8)!, response)
            }
            return (Data(), response)
        }
    }

    private func openMarkdownTab(content: String, name: String = "메모.md") -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        let tab = EditorTab(fileURL: url, kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: content)
        return url
    }

    // MARK: - 진입점

    func testOpenTaskFinderWithNoActiveTabShowsError() {
        app.openTaskFinder()
        XCTAssertTrue(app.showTaskFinder)
        XCTAssertNotNil(app.taskFinderError)
        XCTAssertTrue(app.taskFinderCandidates.isEmpty)
    }

    func testOpenTaskFinderFindsCandidatesAndDefaultsSelection() async {
        app.taskFinderService = TaskFinderService(claude: ScriptedClaude(#"["회의 준비하기"]"#))
        _ = openMarkdownTab(content: "- [ ] 보고서 제출\n본문 설명")
        app.openTaskFinder()

        var tries = 0
        while app.taskFinderCandidates.isEmpty && app.taskFinderError == nil && tries < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }

        XCTAssertEqual(Set(app.taskFinderCandidates.map(\.text)), ["보고서 제출", "회의 준비하기"])
        let checkboxCandidate = app.taskFinderCandidates.first { $0.source == .checkbox }!
        let aiCandidate = app.taskFinderCandidates.first { $0.source == .ai }!
        XCTAssertTrue(app.taskFinderSelected.contains(checkboxCandidate.id), "체크박스 유래는 기본 선택")
        XCTAssertFalse(app.taskFinderSelected.contains(aiCandidate.id), "AI 유래는 기본 미선택(검토 유도)")
    }

    func testCloseTaskFinderResetsState() {
        app.showTaskFinder = true
        app.taskFinderCandidates = [TaskCandidate(text: "x", source: .checkbox)]
        app.closeTaskFinder()
        XCTAssertFalse(app.showTaskFinder)
        XCTAssertTrue(app.taskFinderCandidates.isEmpty)
    }

    // MARK: - Todoist 전송

    func testSendSelectedTasksWithoutTokenSetsError() async {
        app.taskFinderCandidates = [TaskCandidate(text: "할일", source: .checkbox)]
        app.taskFinderSelected = [app.taskFinderCandidates[0].id]
        await app.sendSelectedTasksToTodoist()
        XCTAssertNotNil(app.taskFinderError)
        XCTAssertEqual(app.taskFinderCandidates.count, 1, "토큰 없으면 아무것도 못 보내 목록 그대로")
    }

    func testSendSelectedTasksRemovesSentFromListAndSetsSummary() async {
        let transport = FakeTransport()
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "가짜토큰"
        let candidate = TaskCandidate(text: "보고서 제출", source: .checkbox)
        app.taskFinderCandidates = [candidate]
        app.taskFinderSelected = [candidate.id]

        await app.sendSelectedTasksToTodoist()

        XCTAssertTrue(app.taskFinderCandidates.isEmpty, "보낸 항목은 목록에서 빠져야 한다")
        XCTAssertEqual(app.taskFinderSentSummary, "1개 보냈습니다.")
        let sent = await transport.sentBodies
        XCTAssertEqual(sent.first?["content"] as? String, "보고서 제출")
    }

    func testSendSelectedTasksOnlySendsSelectedOnes() async {
        let transport = FakeTransport()
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "가짜토큰"
        let a = TaskCandidate(text: "보낼 것", source: .checkbox)
        let b = TaskCandidate(text: "안 보낼 것", source: .ai)
        app.taskFinderCandidates = [a, b]
        app.taskFinderSelected = [a.id]

        await app.sendSelectedTasksToTodoist()

        XCTAssertEqual(app.taskFinderCandidates.map(\.text), ["안 보낼 것"], "선택 안 한 건 그대로 남는다")
        let sent = await transport.sentBodies
        XCTAssertEqual(sent.count, 1)
    }

    func testSendSelectedTasksPartialFailureReportsCount() async {
        let transport = FakeTransport(statusCode: 401)
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "틀린토큰"
        let candidate = TaskCandidate(text: "할일", source: .checkbox)
        app.taskFinderCandidates = [candidate]
        app.taskFinderSelected = [candidate.id]

        await app.sendSelectedTasksToTodoist()

        XCTAssertEqual(app.taskFinderSentSummary, "1개 중 0개 보냈습니다.")
        XCTAssertNotNil(app.taskFinderError)
        XCTAssertEqual(app.taskFinderCandidates.count, 1, "실패분은 목록에 남아 재시도 가능")
    }

    // MARK: - 설정: 프로젝트 목록·기본 프로젝트

    func testLoadTodoistProjectsPopulatesList() async {
        let transport = FakeTransport()
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "가짜토큰"
        await app.loadTodoistProjects()
        XCTAssertEqual(app.todoistProjects.count, 2)
        XCTAssertNil(app.todoistProjectsError)
    }

    func testSelectTodoistDefaultProjectPersists() {
        let project = TodoistProject(id: "2", name: "업무", isInboxProject: false)
        app.selectTodoistDefaultProject(project)
        XCTAssertEqual(app.settings.todoistDefaultProjectId, "2")
        XCTAssertEqual(app.settings.todoistDefaultProjectName, "업무")
    }

    func testSelectTodoistDefaultProjectNilMeansInbox() {
        app.settings.todoistDefaultProjectId = "2"
        app.selectTodoistDefaultProject(nil)
        XCTAssertNil(app.settings.todoistDefaultProjectId)
    }
}
