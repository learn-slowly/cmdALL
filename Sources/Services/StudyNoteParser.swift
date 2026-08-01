import Foundation
import Yams

/// 학습 노트 파일(카드/문제) 마크다운을 읽어 앵커 항목을 뽑아내거나(§3.3~3.5), 채점 결과로
/// 앵커 한 줄만 바꾼 새 본문을 만든다(§3.6). 전부 순수 함수 — 디스크 IO는 호출부
/// (`AppState+StudyReview`)가 읽고/쓰고 백업한다. 대화 노트(`study_kind: chat`)는 앵커·복습
/// 대상이 아니라 `items`가 항상 빈 배열이다.
enum StudyNoteParser {

    struct ParsedItem: Equatable {
        let uid: UUID
        let src: String              // 앵커 원시 src 값(percent-encoded 상대경로)
        let loc: StudyLocator
        let state: StudyReviewState
        let title: String            // 앵커 바로 다음 줄("### [카드] 제목" 등)에서 뽑은 제목
        /// 제목 줄 다음부터 다음 앵커(또는 파일 끝) 전까지 원문 그대로(불릿·근거 인용 포함,
        /// 문제는 Q/보기/A/해설까지) — 복습 화면이 이 문자열 하나만 훑으면 된다.
        let body: String
        let lineText: String         // 앵커 원문 그대로 — 재확인(§3.6 "채점 직전 외부 변경")용
    }

    struct ParsedNote: Equatable {
        let studyID: UUID?
        let kind: StudyItemKind?
        let items: [ParsedItem]
    }

    static func parse(_ content: String) -> ParsedNote {
        var studyID: UUID?
        var kind: StudyItemKind?
        if let (yamlString, _) = CompanionNote.splitFrontmatter(content),
           let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any] {
            if let idString = yaml["study_id"] as? String { studyID = UUID(uuidString: idString) }
            if let kindString = yaml["study_kind"] as? String { kind = StudyItemKind(rawValue: kindString) }
        }
        // 대화 노트·frontmatter/study_id 없는 파일은 항목 0건 취급(§3.6).
        guard kind == .card || kind == .question, studyID != nil else {
            return ParsedNote(studyID: studyID, kind: kind, items: [])
        }

        let lines = content.components(separatedBy: "\n")
        var items: [ParsedItem] = []
        var seenUIDs = Set<UUID>()
        for index in lines.indices {
            guard let anchor = parseAnchorLine(lines[index]) else { continue }
            guard !seenUIDs.contains(anchor.uid) else { continue }   // 노트 안 중복 uid: 첫 번째만(§3.6)
            seenUIDs.insert(anchor.uid)
            let title = index + 1 < lines.count ? extractTitle(lines[index + 1]) : ""
            var nextAnchorIndex = lines.count
            for j in (index + 1)..<lines.count where parseAnchorLine(lines[j]) != nil {
                nextAnchorIndex = j
                break
            }
            let bodyStart = min(index + 1, lines.count)
            let body = lines[bodyStart..<nextAnchorIndex].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(ParsedItem(uid: anchor.uid, src: anchor.src, loc: anchor.loc,
                                     state: anchor.state, title: title, body: body, lineText: lines[index]))
        }
        return ParsedNote(studyID: studyID, kind: kind, items: items)
    }

    private static func extractTitle(_ line: String) -> String {
        guard let range = line.range(of: "] ") else { return line }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 앵커 줄 파싱(§3.3) — 알려진 키 8개 + 미지 키 보존.

    private static let knownKeys: Set<String> = ["item", "src", "loc", "due", "ivl", "ease", "reps", "lapses"]

    static func parseAnchorLine(_ raw: String) -> (uid: UUID, src: String, loc: StudyLocator, state: StudyReviewState, extraTokens: [String])? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- study "), trimmed.hasSuffix("-->") else { return nil }
        let inner = String(trimmed.dropFirst("<!-- study ".count).dropLast("-->".count))
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }

        var dict: [String: String] = [:]
        var extra: [String] = []
        for token in inner.split(separator: " ", omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: "=") else { return nil }   // "값에 공백 금지" 위반 → 줄 무효
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            if knownKeys.contains(key) {
                dict[key] = value
            } else {
                extra.append(String(token))
            }
        }
        guard let itemStr = dict["item"], let uid = UUID(uuidString: itemStr),
              let src = dict["src"],
              let locStr = dict["loc"], let loc = StudyNoteWriter.parseAnchorLoc(locStr),
              let dueStr = dict["due"], let due = StudyNoteWriter.parseDay(dueStr),
              let ivlStr = dict["ivl"], let ivl = Int(ivlStr),
              let easeStr = dict["ease"], let ease = Double(easeStr),
              let repsStr = dict["reps"], let reps = Int(repsStr),
              let lapsesStr = dict["lapses"], let lapses = Int(lapsesStr)
        else { return nil }
        let state = StudyReviewState(due: due, interval: ivl, ease: ease, reps: reps, lapses: lapses)
        return (uid, src, loc, state, extra)
    }

    // MARK: - 채점 쓰기(§3.6) — 앵커 줄만 치환.

    /// `content` 안에서 `itemUID` 앵커 줄을 찾아 `expectedLineText`와 정확히 같은지 재확인한 뒤
    /// (§3.6 "채점 직전 외부 변경") 새 상태로 치환한 전체 본문을 돌려준다. 못 찾았거나 그 사이
    /// 줄이 달라졌으면 nil(호출부가 "포기 + 안내"로 처리, 파일에 아무 것도 쓰지 않는다).
    static func replacingAnchorLine(
        in content: String, itemUID: UUID, expectedLineText: String, newState: StudyReviewState
    ) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let index = lines.indices.first(where: { idx in
            guard let anchor = parseAnchorLine(lines[idx]) else { return false }
            return anchor.uid == itemUID
        }) else { return nil }
        guard lines[index] == expectedLineText, let anchor = parseAnchorLine(lines[index]) else { return nil }
        lines[index] = StudyNoteWriter.formatAnchorLine(
            uid: itemUID, src: anchor.src, loc: anchor.loc, state: newState, extraTokens: anchor.extraTokens)
        return lines.joined(separator: "\n")
    }
}
