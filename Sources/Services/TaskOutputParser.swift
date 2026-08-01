import Foundation

/// AI 응답(stdout)에서 할일 JSON 배열을 뽑아 `TaskCandidate`로 바꾼다(순수 함수).
/// 형식이 깨졌거나 빈 배열이면 빈 결과 — 크래시 없이 조용히 실패한다(호출부가 체크박스
/// 결과만이라도 보여준다).
enum TaskOutputParser {
    static let maxItems = 30
    static let maxTextLength = 300

    static func parseAIResponse(_ raw: String, excluding existing: [String] = []) -> [TaskCandidate] {
        guard let jsonString = extractJSONArray(raw),
              let data = jsonString.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }

        let existingSet = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = Set<String>()
        var out: [TaskCandidate] = []
        for raw in items {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maxTextLength,
                  !existingSet.contains(text), !seen.contains(text) else { continue }
            seen.insert(text)
            out.append(TaskCandidate(text: text, source: .ai))
            if out.count >= maxItems { break }
        }
        return out
    }

    /// stdout에서 첫 `[` ~ 마지막 `]` 구간만 추출(전례: `CleanupPlanner.extractJSONObject`의 배열판).
    static func extractJSONArray(_ stdout: String) -> String? {
        guard let start = stdout.firstIndex(of: "["),
              let end = stdout.lastIndex(of: "]"), start < end else { return nil }
        return String(stdout[start...end])
    }
}
