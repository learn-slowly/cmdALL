import Foundation

/// codex CLI(OpenAI Codex — ChatGPT 계정 브라우저 로그인)를 Process로 호출해 질의한다.
/// ClaudeAsking을 구현해 AIRouterService·CleanupService 등이 claude와 동일한 방식으로
/// 다룰 수 있게 한다. 에러는 새 타입을 만들지 않고 ClaudeError를 재사용한다 — provider가
/// 뭐든 상위 코드(에러 메시지 변환·RagOutcome.failed 등)가 같은 타입으로 처리할 수 있게.
actor CodexService: ClaudeAsking {
    // ask()의 기본 Process 타임아웃. ClaudeService와 동일 기본값 — 출력이 긴 호출은
    // ask(…timeout:)으로 상향(WikiIngestService 등 기존 호출부가 이미 그렇게 쓴다).
    private let timeout: TimeInterval = 120

    /// codex 종료코드/에러 메시지를 사용자 분기 에러로 분류한다(순수 함수). ClaudeService.classify와
    /// 같은 키워드 휴리스틱 — codex는 stderr 대신 --json 이벤트의 message 필드로 에러를 준다.
    static func classify(exitCode: Int32, message: String) -> ClaudeError {
        let s = message.lowercased()
        if s.contains("not logged in") || s.contains("unauthorized") || s.contains("401")
            || s.contains("please log in") || s.contains("authenticate") {
            return .notLoggedIn
        }
        if s.contains("quota") || s.contains("rate limit") || s.contains("usage limit")
            || s.contains("429") || s.contains("insufficient") || s.contains("credit") {
            return .creditExhausted
        }
        return .failed(String(message.prefix(500)))
    }

    /// codex exec 호출 인자(순수 함수). 프롬프트=마지막 인자, 컨텍스트=stdin(claude와 동일 패턴 —
    /// exec는 stdin이 파이프되고 프롬프트도 있으면 stdin을 `<stdin>` 블록으로 프롬프트에 덧붙인다).
    /// -s read-only + --skip-git-repo-check: 파일 수정·명령 실행 없이 텍스트 답변만 받는다.
    /// --ignore-user-config: 이 컴퓨터에 개인적으로 설정된 codex 플러그인·MCP 서버가 앱의
    /// 질의마다 끼어들지 않게 격리(실측: 끄지 않으면 관련 없는 경고·지연이 매 호출 섞인다).
    /// --json: stdout을 기계 판독 가능한 JSONL로(사람이 읽는 배너·훅 로그는 전부 stderr로 빠진다).
    static func makeArguments(prompt: String) -> [String] {
        ["exec", "-s", "read-only", "--skip-git-repo-check", "--ignore-user-config", "--json", prompt]
    }

    /// `codex exec --json`의 JSONL 한 줄 한 줄을 훑어 최종 답변과 에러 메시지를 뽑는다(순수 함수).
    /// 마지막 `item.completed`(agent_message)가 답변, `turn.failed`/최상위 `error`가 실패 메시지.
    static func parseEvents(_ jsonl: String) -> (agentMessage: String?, errorMessage: String?) {
        var agentMessage: String?
        var errorMessage: String?
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "item.completed":
                guard let item = obj["item"] as? [String: Any] else { continue }
                switch item["type"] as? String {
                case "agent_message":
                    if let text = item["text"] as? String { agentMessage = text }
                case "error":
                    if let msg = item["message"] as? String { errorMessage = msg }
                default: break
                }
            case "turn.failed":
                if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                    errorMessage = msg
                }
            case "error":
                if let msg = obj["message"] as? String { errorMessage = msg }
            default: break
            }
        }
        return (agentMessage, errorMessage)
    }

    func ask(prompt: String, context: String) async throws -> String {
        try await ask(prompt: prompt, context: context, timeout: timeout)
    }

    /// 컨텍스트와 프롬프트를 codex exec로 보내 최종 답변만 반환한다.
    func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
        guard let codexPath = Self.resolveCodexPath() else { throw ClaudeError.toolNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = Self.makeArguments(prompt: prompt)
        process.environment = SubprocessEnvironment.environment(forTool: codexPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClaudeError.toolNotFound
        }

        // 파이프 버퍼가 차서 교착되지 않게 stdout/stderr 드레인을 먼저 시작한다.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        // 컨텍스트를 stdin으로 주입하고 닫는다 — write가 블록돼도 위 드레인이 동시에 돌게
        // 별도 스레드에서 처리(claude 쪽과 동일 교착 방지 패턴).
        let stdinHandle = stdinPipe.fileHandleForWriting
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdinData = trimmed.data(using: .utf8) ?? Data()
        Task.detached {
            if !stdinData.isEmpty { try? stdinHandle.write(contentsOf: stdinData) }
            try? stdinHandle.close()
        }

        // 타임아웃·취소 감시(협조적 폴링).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() > deadline {
                process.terminate()
                throw ClaudeError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        try Task.checkCancellation()

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""
        let parsed = Self.parseEvents(out)

        if process.terminationStatus != 0 || parsed.agentMessage == nil {
            let message = parsed.errorMessage ?? (err.isEmpty ? out : err)
            throw Self.classify(exitCode: process.terminationStatus, message: message)
        }
        return (parsed.agentMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // codex CLI는 클로드처럼 토큰 단위 실시간 델타를 안 준다(--json도 완성된 agent_message
    // 한 덩어리만 낸다) — askStream은 ClaudeAsking의 기본 구현(ask() 결과를 한 번에 yield)을
    // 그대로 쓴다. 정직한 폴백: "타이핑 효과 없이 한 번에 표시"뿐, 내용·완성도는 동일하다.

    // MARK: - 인증 (codex login)

    /// `codex login status` 결과. CLI를 못 찾으면 nil(미설치).
    func authStatus() async -> CodexAuthStatus? {
        guard let path = Self.resolveCodexPath() else { return nil }
        guard let result = await Self.runCapturing(path: path, arguments: ["login", "status"], timeout: 20)
        else { return CodexAuthStatus.loggedOut }
        // "Logged in using X"는 관측상 stderr로 나가지만 버전마다 바뀔 수 있어 둘 다 본다.
        return CodexAuthParser.parse(result.out + "\n" + result.err)
    }

    /// `codex login` 실행 — 브라우저 로그인 페이지가 열린다. 완료까지 대기(긴 타임아웃).
    /// 실패 시 분류된 에러를 던진다.
    func login() async throws {
        guard let path = Self.resolveCodexPath() else { throw ClaudeError.toolNotFound }
        guard let result = await Self.runCapturing(path: path, arguments: ["login"], timeout: 300)
        else { throw ClaudeError.toolNotFound }
        if result.code != 0 {
            throw Self.classify(exitCode: result.code, message: result.err.isEmpty ? result.out : result.err)
        }
    }

    /// `codex logout`.
    func logout() async throws {
        guard let path = Self.resolveCodexPath() else { throw ClaudeError.toolNotFound }
        _ = await Self.runCapturing(path: path, arguments: ["logout"], timeout: 30)
    }

    /// stdin 없이 인자만으로 codex를 실행해 (stdout, stderr, 종료코드)를 돌려준다.
    /// 실행 자체가 불가하면 nil. 파이프 교착 방지를 위해 드레인을 먼저 시작한다.
    private static func runCapturing(path: String, arguments: [String], timeout: TimeInterval) async -> (out: String, err: String, code: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = SubprocessEnvironment.environment(forTool: path)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline { process.terminate(); break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""
        return (out, err, process.terminationStatus)
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 codex 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which codex`(claude 쪽과 동일 패턴).
    static func resolveCodexPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "/usr/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which codex"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch { }
        return nil
    }
}
