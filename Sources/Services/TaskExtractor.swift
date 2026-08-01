import Foundation

/// 마크다운 본문에서 이미 체크박스로 써둔 할일을 그대로 뽑아낸다(순수 함수, 디스크 IO 없음).
/// 완료 표시(`- [x]`/`- [X]`)는 이미 끝난 일이라 후보에서 뺀다.
enum TaskExtractor {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*[-*+]\s+\[ \]\s+(.+)$"#
    )

    static func checkboxTasks(from markdown: String) -> [TaskCandidate] {
        var out: [TaskCandidate] = []
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let textRange = Range(match.range(at: 1), in: line) else { continue }
            let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(TaskCandidate(text: text, source: .checkbox, lineNumber: index + 1))
        }
        return out
    }
}
