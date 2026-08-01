import Foundation

/// Todoist 프로젝트(REST API v2 응답 일부만 디코드).
struct TodoistProject: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let isInboxProject: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isInboxProject = "is_inbox_project"
    }
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
            return try Self.decodeProjects(data)
        } catch let error as TodoistError {
            throw error
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
    }

    private struct PagedProjects: Decodable { let results: [TodoistProject] }

    private static func decodeProjects(_ data: Data) throws -> [TodoistProject] {
        if let bare = try? JSONDecoder().decode([TodoistProject].self, from: data) {
            return bare
        }
        if let paged = try? JSONDecoder().decode(PagedProjects.self, from: data) {
            return paged.results
        }
        throw TodoistError.network("응답 형식을 읽지 못했습니다.")
    }

    /// - Parameter projectId: nil이면 Todoist 기본 받은함(Inbox)으로 들어간다.
    @discardableResult
    func createTask(content: String, projectId: String?, token: String) async throws -> Bool {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        var body: [String: Any] = ["content": content]
        if let projectId { body["project_id"] = projectId }
        let request = makeRequest("tasks", method: "POST", token: token, body: body)
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
