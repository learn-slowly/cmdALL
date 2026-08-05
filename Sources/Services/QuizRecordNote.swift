import Foundation
import Yams

/// 이미 만들어 둔 문제집(볼트 md)을 앱에서 풀 때 쓰는 **기록장** 읽기·쓰기. 전부 순수 함수 —
/// 디스크 IO는 호출부(`AppState+StudyQuiz`)가 한다(진도 노트와 같은 어법).
///
/// **원본 문제집은 건드리지 않는다.** 발문·보기·정답·해설은 원본에 그대로 두고, 이 파일에는
/// 문항 번호와 복습 상태만 남긴다. 정답이 두 곳에 적히면 반드시 한쪽이 낡기 때문이다 —
/// 2026-08-05에 같은 교재의 100제에서 해설과 요약표가 74곳 어긋난 사고를 겪고 정한 원칙이다
/// (설계 `docs/superpowers/specs/2026-08-05-quiz-solving-design.md` §설계 변경).
///
/// ```markdown
/// ---
/// study_quiz_id: <uuid>
/// study_quiz_source: "%EB%AC%B8%EC%A0%9C%EC%A7%91_1.1.1_100%EB%AC%B8%ED%95%AD.md"
/// study_quiz_book: "%EA%B5%90%EC%9E%AC.pdf"
/// study_quiz_items: 100
/// study_updated: 2026-08-05
/// ---
///
/// # 문제집 기록: 문제집_1.1.1_100문항.md
///
/// <!-- quiz n=1 due=2026-08-05 ivl=0 ease=2.50 reps=0 lapses=0 -->
/// <!-- quiz n=2 due=2026-08-07 ivl=2 ease=2.55 reps=1 lapses=0 -->
/// ```
enum QuizRecordNote {

    struct Parsed: Equatable {
        let quizID: UUID
        /// 원본 문제집 md의 상대경로(percent-encoded, 기록장 폴더 기준).
        let source: String
        /// 교재 원본의 상대경로 — 해설의 쪽으로 교재를 열 때 쓴다. 없을 수 있다.
        let book: String?
        /// 기록장을 만들 당시의 문항 수(원본이 바뀌면 실제와 달라질 수 있다 — `reconciling`이 맞춘다).
        let itemCount: Int
        let records: [QuizRecord]
    }

    /// 기록장을 모아두는 하위 폴더 이름(학습 폴더 밑).
    static let folderName = "문제집기록"

    // MARK: - 쓰기

    /// 기록장 전문. 모든 문항은 오늘부터 시작한다(`StudyReviewState.initial`과 정합).
    static func build(sourceURL: URL, bookURL: URL?, itemCount: Int, noteFolder: URL,
                      now: Date = Date(), makeUUID: () -> UUID = UUID.init) -> String {
        var lines = [
            "---",
            "study_quiz_id: \(makeUUID().uuidString)",
            "study_quiz_source: \(CompanionNote.yamlQuoted(StudyNoteWriter.relativePath(from: noteFolder, to: sourceURL)))",
        ]
        if let bookURL {
            lines.append("study_quiz_book: \(CompanionNote.yamlQuoted(StudyNoteWriter.relativePath(from: noteFolder, to: bookURL)))")
        }
        lines.append("study_quiz_items: \(itemCount)")
        lines.append("study_updated: \(StudyNoteWriter.formatDay(now))")
        lines.append("---")
        lines.append("")
        lines.append("# 문제집 기록: \(sourceURL.lastPathComponent)")
        lines.append("")
        let initial = StudyReviewState.initial(now: now)
        for number in 1...max(1, itemCount) where itemCount >= 1 {
            lines.append(formatAnchorLine(QuizRecord(n: number, state: initial)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 채점 결과로 **그 문항의 앵커 한 줄만** 바꾼 새 본문.
    ///
    /// 쓰기 직전에 `expectedLineText`와 정확히 같은지 다시 확인한다(그 사이 파일이 바뀌었으면
    /// 포기 — 복습 채점과 같은 규약, §3.6). 못 찾았거나 달라졌으면 nil.
    static func replacingAnchorLine(in content: String, number: Int, expectedLineText: String,
                                    newState: StudyReviewState) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let index = lines.indices.first(where: { parseAnchorLine(lines[$0])?.n == number }),
              lines[index] == expectedLineText,
              var record = parseAnchorLine(lines[index]) else { return nil }
        record.state = newState
        lines[index] = formatAnchorLine(record)
        return lines.joined(separator: "\n")
    }

    /// 원본 문항 수가 달라졌을 때 기록장을 맞춘다.
    ///
    /// - 새로 생긴 번호는 오늘부터 시작하는 줄로 **더한다**.
    /// - 원본에서 사라진 번호의 기록은 **지우지 않고 남긴다**(원본을 되돌리면 기록도 살아난다.
    ///   지우는 것은 되돌릴 수 없으므로 "삭제하지 않는다"는 프로젝트 규칙을 따른다).
    /// - 이미 있는 번호는 한 글자도 건드리지 않는다.
    ///
    /// 바꿀 것이 없으면 nil(파일에 쓰지 않는다).
    static func reconciling(content: String, itemCount: Int, now: Date = Date()) -> String? {
        let parsed = parse(content)
        let existing = Set((parsed?.records ?? []).map(\.n))
        let missing = (1...max(1, itemCount)).filter { itemCount >= 1 && !existing.contains($0) }
        guard !missing.isEmpty else { return nil }

        var lines = content.components(separatedBy: "\n")
        let initial = StudyReviewState.initial(now: now)
        let insertAt = (lines.lastIndex { parseAnchorLine($0) != nil }).map { $0 + 1 } ?? lines.count
        let added = missing.map { formatAnchorLine(QuizRecord(n: $0, state: initial)) }
        lines.insert(contentsOf: added, at: insertAt)
        return updatingItemCount(lines.joined(separator: "\n"), to: itemCount, now: now)
    }

    /// frontmatter의 `study_quiz_items`·`study_updated`만 갈아끼운다.
    private static func updatingItemCount(_ content: String, to itemCount: Int, now: Date) -> String {
        var lines = content.components(separatedBy: "\n")
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("study_quiz_items:") {
                lines[index] = "study_quiz_items: \(itemCount)"
            } else if trimmed.hasPrefix("study_updated:") {
                lines[index] = "study_updated: \(StudyNoteWriter.formatDay(now))"
            } else if trimmed == "---", index > 0 {
                break                                   // frontmatter 끝 — 본문은 건드리지 않는다
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 읽기

    static func parse(_ content: String) -> Parsed? {
        guard let (yamlString, _) = CompanionNote.splitFrontmatter(content),
              let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any],
              let idString = yaml["study_quiz_id"] as? String,
              let quizID = UUID(uuidString: idString),
              let source = yaml["study_quiz_source"] as? String
        else { return nil }

        var records: [QuizRecord] = []
        var seen = Set<Int>()
        for line in content.components(separatedBy: "\n") {
            guard let record = parseAnchorLine(line), !seen.contains(record.n) else { continue }
            seen.insert(record.n)
            records.append(record)
        }
        return Parsed(quizID: quizID, source: source,
                      book: yaml["study_quiz_book"] as? String,
                      itemCount: intValue(yaml["study_quiz_items"]) ?? records.count,
                      records: records.sorted { $0.n < $1.n })
    }

    // MARK: - 앵커 한 줄

    /// `<!-- quiz n=1 due=2026-08-05 ivl=0 ease=2.50 reps=0 lapses=0 -->`
    /// 값에 공백을 넣지 않는 규칙은 카드·문제·진도 앵커와 같다.
    static func formatAnchorLine(_ record: QuizRecord) -> String {
        let state = record.state
        var tokens = [
            "n=\(record.n)",
            "due=\(StudyNoteWriter.formatDay(state.due))",
            "ivl=\(state.interval)",
            "ease=\(String(format: "%.2f", state.ease))",
            "reps=\(state.reps)",
            "lapses=\(state.lapses)",
        ]
        tokens.append(contentsOf: record.extraTokens)
        return "<!-- quiz " + tokens.joined(separator: " ") + " -->"
    }

    static func parseAnchorLine(_ raw: String) -> QuizRecord? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- quiz "), trimmed.hasSuffix("-->") else { return nil }
        let inner = String(trimmed.dropFirst("<!-- quiz ".count).dropLast("-->".count))
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }

        let known: Set<String> = ["n", "due", "ivl", "ease", "reps", "lapses"]
        var dict: [String: String] = [:]
        var extra: [String] = []
        for token in inner.split(separator: " ", omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: "=") else { return nil }   // 값에 공백 → 줄 무효
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            if known.contains(key) { dict[key] = value } else { extra.append(String(token)) }
        }
        guard let n = dict["n"].flatMap(Int.init), n >= 1,
              let due = dict["due"].flatMap(StudyNoteWriter.parseDay),
              let ivl = dict["ivl"].flatMap(Int.init),
              let ease = dict["ease"].flatMap(Double.init),
              let reps = dict["reps"].flatMap(Int.init),
              let lapses = dict["lapses"].flatMap(Int.init)
        else { return nil }
        return QuizRecord(n: n,
                          state: StudyReviewState(due: due, interval: ivl, ease: ease,
                                                  reps: reps, lapses: lapses),
                          extraTokens: extra)
    }

    // MARK: - 파일 이름

    /// 원본 문제집 파일 이름 그대로 기록장 이름을 만든다(어느 문제집의 기록인지 한눈에).
    static func fileName(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "문제집" : base) + ".md"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let text = any as? String { return Int(text) }
        return nil
    }
}
