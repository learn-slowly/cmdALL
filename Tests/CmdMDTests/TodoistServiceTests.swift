import XCTest
@testable import CmdMD

/// cmdALL의 첫 실제 외부 API 연동 — `TodoistService`가 요청을 올바르게 조립하고
/// (토큰 헤더·project_id 유무), 응답 상태 코드를 정확한 에러로 매핑하는지 확인한다.
/// 실제 인터넷 호출은 하지 않는다(`TodoistTransport`를 가짜로 주입).
final class TodoistServiceTests: XCTestCase {

    private actor FakeTransport: TodoistTransport {
        enum Script {
            case success(Data, Int)
            case httpError(Int)
            case throwing(Error)
        }
        private let script: Script
        private(set) var lastRequest: URLRequest?

        init(_ script: Script) { self.script = script }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lastRequest = request
            switch script {
            case .success(let data, let code):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (data, response)
            case .httpError(let code):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            case .throwing(let error):
                throw error
            }
        }
    }

    private struct DummyError: Error {}

    // MARK: - fetchProjects

    func testFetchProjectsDecodesSuccessResponse() async throws {
        let json = #"[{"id":"1","name":"Inbox","inbox_project":true},{"id":"2","name":"업무","inbox_project":false}]"#
        let transport = FakeTransport(.success(json.data(using: .utf8)!, 200))
        let service = TodoistService(transport: transport)
        let projects = try await service.fetchProjects(token: "가짜토큰")
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[1].name, "업무")
        XCTAssertTrue(projects[0].isInboxProject)
    }

    /// 2026-08-01 — 410 실사용 사고 이후, v1 API의 페이지네이션 감싼 응답 형식도 받아들이는지.
    func testFetchProjectsDecodesPagedResultsWrapper() async throws {
        let json = #"{"results":[{"id":"1","name":"Inbox","inbox_project":true}],"next_cursor":null}"#
        let transport = FakeTransport(.success(json.data(using: .utf8)!, 200))
        let service = TodoistService(transport: transport)
        let projects = try await service.fetchProjects(token: "가짜토큰")
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "Inbox")
    }

    func testFetchProjectsWithoutTokenThrowsNoToken() async {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.fetchProjects(token: "")
            XCTFail("토큰 없이는 실패해야 한다")
        } catch {
            XCTAssertEqual(error as? TodoistError, .noToken)
        }
    }

    func testFetchProjects401MapsToInvalidToken() async {
        let transport = FakeTransport(.httpError(401))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.fetchProjects(token: "틀린토큰")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TodoistError, .invalidToken)
        }
    }

    func testFetchProjects500MapsToServerError() async {
        let transport = FakeTransport(.httpError(500))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.fetchProjects(token: "토큰")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TodoistError, .serverError(500))
        }
    }

    func testFetchProjectsNetworkFailureMapsToNetworkError() async {
        let transport = FakeTransport(.throwing(DummyError()))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.fetchProjects(token: "토큰")
            XCTFail()
        } catch {
            guard case .network = error as? TodoistError else { return XCTFail("network 에러여야 함") }
        }
    }

    // MARK: - createTask

    func testCreateTaskSendsAuthorizationHeaderAndContent() async throws {
        let json = #"{"id":"999","content":"보고서 제출","priority":1,"checked":false}"#
        let transport = FakeTransport(.success(json.data(using: .utf8)!, 200))
        let service = TodoistService(transport: transport)
        let created = try await service.createTask(content: "보고서 제출", projectId: nil, token: "내토큰")
        XCTAssertEqual(created?.id, "999", "생성 응답을 디코드해 id를 돌려줘야 한다(보낸 기록 연결용)")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer 내토큰")
        let body = try XCTUnwrap(request?.httpBody)
        let bodyJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(bodyJSON["content"] as? String, "보고서 제출")
        XCTAssertNil(bodyJSON["project_id"], "project_id를 안 주면 요청 본문에도 없어야 한다(Inbox로 감)")
    }

    func testCreateTaskWithUndecodableResponseStillSucceeds() async throws {
        // 응답 본문이 예상과 달라도(빈 값 등) 전송 자체(2xx)는 성공으로 본다 — created만 nil.
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        let created = try await service.createTask(content: "할일", projectId: nil, token: "토큰")
        XCTAssertNil(created)
    }

    func testCreateTaskIncludesProjectIdWhenProvided() async throws {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        _ = try await service.createTask(content: "할일", projectId: "42", token: "토큰")
        let request = await transport.lastRequest
        let body = try XCTUnwrap(request?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["project_id"] as? String, "42")
    }

    func testCreateTaskWithoutTokenThrowsNoToken() async {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.createTask(content: "x", projectId: nil, token: "")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TodoistError, .noToken)
        }
    }

    // MARK: - fetchTasks

    func testFetchTasksDecodesPagedResultsWrapper() async throws {
        let json = #"{"results":[{"id":"1","content":"보고서 제출","project_id":"10","priority":2,"checked":false,"due":{"date":"2026-08-05","string":"tomorrow","is_recurring":false}}],"next_cursor":null}"#
        let transport = FakeTransport(.success(json.data(using: .utf8)!, 200))
        let service = TodoistService(transport: transport)
        let tasks = try await service.fetchTasks(token: "가짜토큰")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].content, "보고서 제출")
        XCTAssertEqual(tasks[0].projectId, "10")
        XCTAssertEqual(tasks[0].due?.string, "tomorrow")
    }

    func testFetchTasksWithoutTokenThrowsNoToken() async {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.fetchTasks(token: "")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TodoistError, .noToken)
        }
    }

    // MARK: - closeTask

    func testCloseTaskSendsCorrectPath() async throws {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        let ok = try await service.closeTask(taskId: "123", token: "토큰")
        XCTAssertTrue(ok)
        let request = await transport.lastRequest
        XCTAssertTrue(request?.url?.path.hasSuffix("/tasks/123/close") ?? false)
        XCTAssertEqual(request?.httpMethod, "POST")
    }

    func testCloseTask401MapsToInvalidToken() async {
        let transport = FakeTransport(.httpError(401))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.closeTask(taskId: "123", token: "틀린토큰")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TodoistError, .invalidToken)
        }
    }

    // MARK: - reopenTask(완료 되돌리기, 다듬기 D)

    func testReopenTaskSendsCorrectPath() async throws {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        let ok = try await service.reopenTask(taskId: "123", token: "토큰")
        XCTAssertTrue(ok)
        let request = await transport.lastRequest
        XCTAssertTrue(request?.url?.path.hasSuffix("/tasks/123/reopen") ?? false)
        XCTAssertEqual(request?.httpMethod, "POST")
    }

    func testReopenTaskWithoutTokenThrowsNoToken() async {
        let transport = FakeTransport(.success(Data(), 200))
        let service = TodoistService(transport: transport)
        do {
            _ = try await service.reopenTask(taskId: "123", token: "   ")
            XCTFail("토큰이 비면 부르기 전에 막아야 한다")
        } catch {
            XCTAssertEqual(error as? TodoistError, .noToken)
        }
    }

    // MARK: - TodoistDue.parsedDate(간트차트 막대 계산용)

    func testParsedDateHandlesPlainDayFormat() {
        let due = TodoistDue(date: "2026-08-05", string: "tomorrow", isRecurring: false)
        XCTAssertNotNil(due.parsedDate)
    }

    func testParsedDateHandlesISO8601Format() {
        let due = TodoistDue(date: "2026-08-05T12:00:00Z", string: "tomorrow at noon", isRecurring: false)
        XCTAssertNotNil(due.parsedDate)
    }

    func testParsedDateReturnsNilForGarbage() {
        let due = TodoistDue(date: "그냥이상한값", string: "?", isRecurring: false)
        XCTAssertNil(due.parsedDate)
    }

    // MARK: - 에러 안내 문구(순수)

    func testErrorMessagesAreKoreanAndDistinct() {
        let messages: Set<String> = [
            TodoistService.errorMessage(TodoistError.noToken),
            TodoistService.errorMessage(TodoistError.invalidToken),
            TodoistService.errorMessage(TodoistError.serverError(500)),
            TodoistService.errorMessage(TodoistError.network("오프라인")),
        ]
        XCTAssertEqual(messages.count, 4, "메시지 4종이 서로 달라야 한다")
    }
}
