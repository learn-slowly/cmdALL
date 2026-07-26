import Foundation

/// `codex login status`의 결과(해석 완료). codex CLI는 클로드처럼 JSON 상태를 안 주고
/// "Logged in using X" / "Not logged in" 같은 평문을 stderr에 찍으므로 텍스트로 판별한다.
struct CodexAuthStatus: Equatable {
    let loggedIn: Bool
    let method: String?   // 예: "ChatGPT", "an API key", "an access token"

    /// 로그인 안 된(또는 상태를 못 읽은) 기본값.
    static let loggedOut = CodexAuthStatus(loggedIn: false, method: nil)
}

/// `codex login status` 출력(stdout+stderr) 파싱 전용 순수 헬퍼(테스트 대상).
enum CodexAuthParser {
    /// "…Logged in using <방식>…" 패턴을 대소문자 무관으로 찾는다. 못 찾으면(빈 출력·
    /// "Not logged in" 포함) 로그아웃으로 취급 — 오검출보다 보수적 폴백이 안전하다.
    static func parse(_ output: String) -> CodexAuthStatus {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .loggedOut }
        guard let range = trimmed.range(of: "logged in using", options: [.caseInsensitive]) else {
            return .loggedOut
        }
        let rest = String(trimmed[range.upperBound...])
        let method = rest.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return CodexAuthStatus(loggedIn: true, method: method.isEmpty ? nil : method)
    }
}
