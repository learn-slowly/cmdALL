import Foundation

/// 생성된 카드·문제(§O1~O6)를 학습 노트 마크다운(§3.3~3.5)으로 옮긴다. 순수 함수 —
/// 디스크에 쓰지 않는다(AC #6 "취소 시 디스크 변화 0"). 실제 파일 생성은 사용자가 저장을
/// 눌렀을 때 호출부(다음 조각 `StudyHelperView`/`AppState`)가 이 함수의 반환 문자열을
/// 그대로 `write(to:)`한다 — `saveClaudeResponseAsNote()` 전례와 같은 어법.
enum StudyNoteWriter {

    struct BuildResult: Equatable {
        /// frontmatter + 항목 앵커·본문 전체(파일 그대로 쓰면 되는 문자열).
        let body: String
        /// 발급 순서 = 항목 순서(카드·문제 배열과 1:1 대응) — 테스트·후속 인덱싱 편의용.
        let itemUIDs: [UUID]
    }

    // MARK: - 카드 노트

    static func buildCardNote(
        cards: [StudyCard], scope: StudyScope, noteFolder: URL, title: String,
        now: Date = Date(), makeUUID: () -> UUID = UUID.init
    ) -> BuildResult {
        let noteID = makeUUID()
        let uids = cards.map { _ in makeUUID() }
        let bodyBlocks = zip(cards, uids).map { card, uid in
            anchor(uid: uid, scope: scope, noteFolder: noteFolder, locator: card.locator, now: now)
                + "\n" + cardBlock(card)
        }
        return BuildResult(
            body: frontmatter(noteID: noteID, kind: .card, scope: scope, noteFolder: noteFolder,
                               itemCount: cards.count, now: now) + "\n# \(title)\n\n"
                + bodyBlocks.joined(separator: "\n\n") + "\n",
            itemUIDs: uids
        )
    }

    private static func cardBlock(_ card: StudyCard) -> String {
        var lines = ["### [카드] \(card.title)"]
        lines.append(contentsOf: card.bullets.map { "- \($0)" })
        lines.append("> 근거: \(bracketTag(card.locator)) \"\(card.quote)\"")
        return lines.joined(separator: "\n")
    }

    // MARK: - 문제 노트

    static func buildQuestionNote(
        questions: [StudyQuestion], scope: StudyScope, noteFolder: URL, title: String,
        now: Date = Date(), makeUUID: () -> UUID = UUID.init
    ) -> BuildResult {
        let noteID = makeUUID()
        let uids = questions.map { _ in makeUUID() }
        let bodyBlocks = zip(questions, uids).enumerated().map { index, pair -> String in
            let (question, uid) = pair
            return anchor(uid: uid, scope: scope, noteFolder: noteFolder, locator: question.locator, now: now)
                + "\n" + questionBlock(question, number: index + 1)
        }
        return BuildResult(
            body: frontmatter(noteID: noteID, kind: .question, scope: scope, noteFolder: noteFolder,
                               itemCount: questions.count, now: now) + "\n# \(title)\n\n"
                + bodyBlocks.joined(separator: "\n\n") + "\n",
            itemUIDs: uids
        )
    }

    private static func questionBlock(_ question: StudyQuestion, number: Int) -> String {
        var lines = ["### [문제 \(number)] \(question.title)"]
        lines.append("type: \(question.type)")
        lines.append("Q: \(question.prompt)")
        for (index, option) in question.options.enumerated() {
            lines.append("\(index + 1)) \(option)")
        }
        lines.append("A: \(question.answer)")
        lines.append("해설: \(question.explanation)")
        lines.append("> 근거: \(bracketTag(question.locator)) \"\(question.quote)\"")
        return lines.joined(separator: "\n")
    }

    // MARK: - frontmatter(§3.5) · 앵커(§3.3)

    private static func frontmatter(
        noteID: UUID, kind: StudyItemKind, scope: StudyScope, noteFolder: URL, itemCount: Int, now: Date
    ) -> String {
        """
        ---
        study_id: \(noteID.uuidString)
        study_kind: \(kind.rawValue)
        study_source: \(CompanionNote.yamlQuoted(relativePath(from: noteFolder, to: scope.fileURL)))
        study_source_kind: \(scope.kind.rawValue)
        study_created: \(isoFormatter.string(from: now))
        study_items: \(itemCount)
        study_due: \(dayFormatter.string(from: now))
        ---

        """
    }

    /// §3.3 앵커 정규 문법 — 새로 만든 항목은 항상 오늘 시작(§3.9 초기값, `StudyReviewState.initial`과 정합).
    private static func anchor(uid: UUID, scope: StudyScope, noteFolder: URL, locator: StudyLocator, now: Date) -> String {
        let initial = StudyReviewState.initial(now: now)
        let ease = String(format: "%.2f", initial.ease)
        return "<!-- study item=\(uid.uuidString) src=\(relativePath(from: noteFolder, to: scope.fileURL)) "
            + "loc=\(anchorLoc(locator)) due=\(dayFormatter.string(from: initial.due)) "
            + "ivl=\(initial.interval) ease=\(ease) reps=\(initial.reps) lapses=\(initial.lapses) -->"
    }

    // MARK: - 위치 표기 변환(앵커용 `p12`/`l345`/`-` · 본문 인용용 `[[p12]]`, §3.3·O1)

    private static func anchorLoc(_ locator: StudyLocator) -> String {
        switch locator {
        case .page(let n): return "p\(n)"
        case .pageRange(let a, let b): return "p\(a)-\(b)"
        case .line(let n): return "l\(n)"
        case .unknown: return "-"
        }
    }

    private static func bracketTag(_ locator: StudyLocator) -> String {
        switch locator {
        case .page(let n): return "[[p\(n)]]"
        case .pageRange(let a, let b): return "[[p\(a)-\(b)]]"
        case .line(let n): return "[[l\(n)]]"
        case .unknown: return "[[?]]"
        }
    }

    // MARK: - 상대 경로(§3.3 "percent-encoded-relpath") — 노트 폴더 기준, 공통 조상 뒤로는 `..`.

    static func relativePath(from noteFolder: URL, to fileURL: URL) -> String {
        let baseComponents = noteFolder.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        var shared = 0
        while shared < baseComponents.count, shared < fileComponents.count,
              baseComponents[shared] == fileComponents[shared] {
            shared += 1
        }
        let upCount = baseComponents.count - shared
        var relComponents = Array(repeating: "..", count: max(0, upCount))
        relComponents.append(contentsOf: fileComponents[shared...])
        let raw = relComponents.joined(separator: "/")
        return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    // MARK: - 날짜 포맷(전례: `CompanionNote.initialContent`·`Document.toYAML`)

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
