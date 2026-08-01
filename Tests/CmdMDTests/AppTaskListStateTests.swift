import XCTest
@testable import CmdMD

/// "할일 목록 보기" — `AppState+TaskList.swift` 배선(Todoist 실시간 목록·완료 처리·보낸
/// 기록)이 임시 디렉터리 격리 상태에서 정확히 동작하는지 확인한다. API 계약 자체는
/// `TodoistServiceTests`가 이미 검증했으므로 여기선 "이어 붙임"만 본다.
@MainActor
final class AppTaskListStateTests: XCTestCase {
    var tempData: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        super.tearDown()
    }

    private actor FakeTransport: TodoistTransport {
        private(set) var closedTaskIds: [String] = []
        private let closeStatusCode: Int
        init(closeStatusCode: Int = 200) { self.closeStatusCode = closeStatusCode }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url!.path
            if path.hasSuffix("/close") {
                closedTaskIds.append(String(path.split(separator: "/").dropLast().last ?? ""))
                let response = HTTPURLResponse(url: request.url!, statusCode: closeStatusCode, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("tasks") {
                let json = #"""
                {"results":[
                  {"id":"1","content":"할일 하나","project_id":"10","priority":1,"checked":false},
                  {"id":"2","content":"할일 둘","project_id":"20","priority":2,"checked":false}
                ],"next_cursor":null}
                """#
                return (json.data(using: .utf8)!, response)
            }
            if path.hasSuffix("projects") {
                let json = #"{"results":[{"id":"10","name":"업무","inbox_project":false}],"next_cursor":null}"#
                return (json.data(using: .utf8)!, response)
            }
            return (Data(), response)
        }
    }

    // MARK: - 진입점·목록 불러오기

    func testOpenTaskListViewLoadsTodoistTasksAndProjects() async {
        app.todoistService = TodoistService(transport: FakeTransport())
        app.settings.todoistAPIToken = "가짜토큰"
        app.openTaskListView()

        var tries = 0
        while app.todoistTasks.isEmpty && app.todoistTasksError == nil && tries < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }

        XCTAssertTrue(app.showTaskListView)
        XCTAssertEqual(app.todoistTasks.map(\.content), ["할일 하나", "할일 둘"])
    }

    func testRefreshTodoistTasksWithoutTokenSetsError() async {
        await app.refreshTodoistTasks()
        XCTAssertNotNil(app.todoistTasksError)
        XCTAssertTrue(app.todoistTasks.isEmpty)
    }

    func testCloseTaskListViewHidesSheet() {
        app.showTaskListView = true
        app.closeTaskListView()
        XCTAssertFalse(app.showTaskListView)
    }

    // MARK: - 완료 처리(양방향 — 레고 결정)

    func testCompleteTodoistTaskRemovesFromListOnSuccess() async {
        let transport = FakeTransport()
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "가짜토큰"
        let task = TodoistTask(id: "1", content: "할일 하나", projectId: "10", priority: 1, due: nil, checked: false)
        app.todoistTasks = [task]

        await app.completeTodoistTask(task)

        XCTAssertTrue(app.todoistTasks.isEmpty)
        let closed = await transport.closedTaskIds
        XCTAssertEqual(closed, ["1"])
    }

    func testCompleteTodoistTaskKeepsTaskOnFailure() async {
        let transport = FakeTransport(closeStatusCode: 500)
        app.todoistService = TodoistService(transport: transport)
        app.settings.todoistAPIToken = "가짜토큰"
        let task = TodoistTask(id: "1", content: "할일 하나", projectId: "10", priority: 1, due: nil, checked: false)
        app.todoistTasks = [task]

        await app.completeTodoistTask(task)

        XCTAssertEqual(app.todoistTasks, [task], "실패하면 목록에서 안 지워져야 한다(낙관적 갱신 없음)")
        XCTAssertNotNil(app.todoistTasksError)
    }

    func testCompleteTodoistTaskWithoutTokenSetsError() async {
        let task = TodoistTask(id: "1", content: "할일 하나", projectId: nil, priority: 1, due: nil, checked: false)
        app.todoistTasks = [task]
        await app.completeTodoistTask(task)
        XCTAssertNotNil(app.todoistTasksError)
        XCTAssertEqual(app.todoistTasks, [task])
    }

    // MARK: - 보낸 기록 탭

    func testLoadSentTaskRecordsPopulatesFromStore() async {
        let record = SentTaskRecord(id: UUID(), text: "보고서 제출", sourceFileName: "메모.md",
                                     sourcePath: "/tmp/메모.md", sentAt: Date(), todoistTaskId: "9")
        await app.sentTaskLogStore.append(record)
        await app.loadSentTaskRecords()
        XCTAssertEqual(app.sentTaskRecords, [record])
    }
}
