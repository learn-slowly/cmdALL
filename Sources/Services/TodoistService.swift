import Foundation

/// Todoist 프로젝트(REST API v2 응답 일부만 디코드).
struct TodoistProject: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let isInboxProject: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        // 실제 필드명은 `inbox_project`다(공식 문서 응답 예시로 실측 확인, 2026-08-01 —
        // 처음엔 REST v2 시절 이름 `is_inbox_project`로 잘못 가정해 디코드가 조용히 실패했었다).
        case isInboxProject = "inbox_project"
    }
}

/// Todoist 할일 하나(응답 필드 전부가 아니라 화면에 필요한 것만 — 공식 문서 `Get Tasks`/
/// `Create Task` 응답 예시로 실측 확인, 2026-08-01).
struct TodoistTask: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let content: String
    let projectId: String?
    let priority: Int
    let due: TodoistDue?
    let checked: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, priority, checked
        case projectId = "project_id"
        case due
    }
}

struct TodoistDue: Equatable, Codable, Sendable {
    let date: String
    let string: String
    let isRecurring: Bool

    enum CodingKeys: String, CodingKey {
        case date, string
        case isRecurring = "is_recurring"
    }

    /// `date`는 보통 "yyyy-MM-dd"(날짜만)지만, 시간이 붙은 마감(due_datetime)은 ISO8601로
    /// 올 수도 있어 둘 다 시도한다(간트차트 막대 계산용, 실패하면 nil — 그 항목은 차트에서 빠진다).
    var parsedDate: Date? {
        if let d = Self.dayFormatter.date(from: date) { return d }
        return Self.isoFormatter.date(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum TodoistError: Error, Equatable {
    case noToken
    /// 401/403 — 토큰이 없거나 잘못됨.
    case invalidToken
    case serverError(Int)
    case network(String)
}

/// HTTP 전송 계층만 추상화(테스트가 실제 인터넷 호출 없이 가짜 응답을 주입할 수 있게).
/// 실제 앱은 `URLSessionTodoistTransport`(기본값)를 쓴다.
protocol TodoistTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTodoistTransport: TodoistTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// cmdALL이 처음으로 다루는 "바깥 인터넷 서비스" 연동 — kordoc·claude처럼 로컬 CLI가
/// 아니라 진짜 HTTPS 호출이다. 토큰은 `AppSettings.todoistAPIToken`에 평문 저장된다
/// (다른 설정값과 같은 파일 — 이 컴퓨터 접근 권한이 있으면 볼 수 있다는 뜻, 개인용 로컬
/// 앱이라는 전제하에 감수한 트레이드오프).
///
/// **2026-08-01 주소 정정**: 처음엔 `rest/v2/`로 만들었는데 레고 실사용 중 그 주소가
/// **410 Gone**(완전히 폐지됨)으로 확인됐다 — Todoist가 REST v2를 접고 통합 `api/v1/`로
/// 옮겼다. `GET /api/v1/tasks`·`GET /api/v1/projects`가 401(인증 필요, 즉 주소 자체는
/// 살아있음)을 돌려주는 것으로 새 경로를 실측 확인했다.
actor TodoistService {
    private let transport: TodoistTransport
    private static let baseURL = "https://api.todoist.com/api/v1/"

    init(transport: TodoistTransport = URLSessionTodoistTransport()) {
        self.transport = transport
    }

    private func makeRequest(_ path: String, method: String, token: String, body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// 응답 형식을 딱 하나로 단정하지 않는다 — 예전 REST v2는 배열을 그대로 줬고, 새 v1은
    /// `{"results": [...], "next_cursor": ...}`로 페이지네이션 감싸서 준다는 보고가 있다.
    /// 실사용 중 형식이 또 바뀌어도(레고가 겪은 410처럼) 앱이 조용히 죽지 않게 둘 다 시도한다.
    func fetchProjects(token: String) async throws -> [TodoistProject] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        let request = makeRequest("projects", method: "GET", token: token)
        do {
            let (data, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return try Self.decodeList(data, as: TodoistProject.self)
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    private struct PagedResults<T: Decodable>: Decodable { let results: [T] }

    /// 배열을 바로 주는 옛 형식과 `{results:[...], next_cursor}`로 감싼 새 형식 둘 다 시도.
    private static func decodeList<T: Decodable>(_ data: Data, as type: T.Type) throws -> [T] {
        if let bare = try? JSONDecoder().decode([T].self, from: data) {
            return bare
        }
        if let paged = try? JSONDecoder().decode(PagedResults<T>.self, from: data) {
            return paged.results
        }
        throw TodoistError.network("응답 형식을 읽지 못했습니다.")
    }

    /// 등록된 모든 프로젝트를 통틀어 활성(완료 안 된) 할일을 가져온다(§scope_filter 레고 결정).
    func fetchTasks(token: String) async throws -> [TodoistTask] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        let request = makeRequest("tasks", method: "GET", token: token)
        do {
            let (data, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return try Self.decodeList(data, as: TodoistTask.self)
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    /// - Parameter projectId: nil이면 Todoist 기본 받은함(Inbox)으로 들어간다.
    /// - Returns: 생성된 할일(가능하면 — 응답 디코드에 실패해도 전송 자체는 성공으로 본다.
    ///   호출부가 `todoistTaskId`를 기록하지 못할 뿐 사용자에게는 실패로 보이지 않는다).
    @discardableResult
    func createTask(content: String, projectId: String?, token: String) async throws -> TodoistTask? {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        var body: [String: Any] = ["content": content]
        if let projectId { body["project_id"] = projectId }
        let request = makeRequest("tasks", method: "POST", token: token, body: body)
        do {
            let (data, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return try? JSONDecoder().decode(TodoistTask.self, from: data)
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    /// 할일을 완료 처리한다(§complete_action 레고 결정 — 앱에서 체크하면 Todoist도 완료됨).
    @discardableResult
    func closeTask(taskId: String, token: String) async throws -> Bool {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        let request = makeRequest("tasks/\(taskId)/close", method: "POST", token: token)
        do {
            let (_, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return true
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    /// 완료 처리를 되돌린다(다듬기 D, 2026-08-02 — 실수로 체크했을 때). Todoist의 `reopen`은
    /// 완료된 할일을 다시 활성 상태로 돌린다.
    @discardableResult
    func reopenTask(taskId: String, token: String) async throws -> Bool {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        let request = makeRequest("tasks/\(taskId)/reopen", method: "POST", token: token)
        do {
            let (_, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return true
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw TodoistError.invalidToken }
        guard (200..<300).contains(http.statusCode) else { throw TodoistError.serverError(http.statusCode) }
    }

    /// 에러를 한국어 안내로(전례: `AppState.claudeErrorMessage`).
    nonisolated static func errorMessage(_ error: Error) -> String {
        switch error {
        case TodoistError.noToken:
            return "Todoist 연동 토큰이 설정돼 있지 않습니다. 설정에서 먼저 입력해 주세요."
        case TodoistError.invalidToken:
            return "Todoist 토큰이 올바르지 않습니다. 설정에서 토큰을 다시 확인해 주세요."
        case TodoistError.serverError(let code):
            return "Todoist 서버 오류(코드 \(code))입니다. 잠시 후 다시 시도해 주세요."
        case TodoistError.network(let message):
            return "Todoist에 연결하지 못했습니다: \(message)"
        default:
            return "Todoist 연동에 실패했습니다: \(error.localizedDescription)"
        }
    }
}
