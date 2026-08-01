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
/// 아니라 진짜 HTTPS 호출이다(Todoist REST API v2). 토큰은 `AppSettings.todoistAPIToken`에
/// 평문 저장된다(다른 설정값과 같은 파일 — 이 컴퓨터 접근 권한이 있으면 볼 수 있다는 뜻,
/// 개인용 로컬 앱이라는 전제하에 감수한 트레이드오프).
actor TodoistService {
    private let transport: TodoistTransport
    private static let baseURL = "https://api.todoist.com/rest/v2/"

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

    func fetchProjects(token: String) async throws -> [TodoistProject] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw TodoistError.noToken }
        let request = makeRequest("projects", method: "GET", token: token)
        do {
            let (data, response) = try await transport.send(request)
            try Self.checkStatus(response)
            return try JSONDecoder().decode([TodoistProject].self, from: data)
        } catch let error as TodoistError {
            throw error
        } catch is DecodingError {
            throw TodoistError.network("응답 형식을 읽지 못했습니다.")
        } catch {
            throw TodoistError.network(error.localizedDescription)
        }
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
