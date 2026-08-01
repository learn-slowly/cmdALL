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
    // MARK: - 대화 노트(S3, "노트로 남기기")

    /// 화면의 턴 전문을 그대로 옮긴다(AC #21). 카드·문제와 달리 항목 앵커·복습 스케줄이
    /// 없다 — 대화는 복습 대상이 아니다(§Out of scope). frontmatter 뒤에 참고한 핀 발췌 +
    /// 턴을 순서대로 나열할 뿐인 순수 함수(디스크에 쓰지 않는다, 호출부가 write(to:)한다).
    static func buildChatNote(
        session: StudyChatSession, sourceKind: DocumentKind?, noteFolder: URL, title: String,
        now: Date = Date(), makeUUID: () -> UUID = UUID.init
    ) -> BuildResult {
        let noteID = makeUUID()
        var lines = ["---", "study_id: \(noteID.uuidString)", "study_kind: chat"]
        if let sourceURL = session.sourceURL {
            lines.append("study_source: \(CompanionNote.yamlQuoted(relativePath(from: noteFolder, to: sourceURL)))")
        }
        if let sourceKind {
            lines.append("study_source_kind: \(sourceKind.rawValue)")
        }
        lines.append("study_created: \(isoFormatter.string(from: now))")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")

        let pinned = session.pinnedExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty {
            lines.append("")
            lines.append("## 참고한 부분")
            lines.append("")
            lines.append(session.pinnedExcerpt)
        }

        lines.append("")
        lines.append("## 대화")
        for turn in session.turns {
            lines.append("")
            lines.append(turn.role == .user ? "### 사용자" : "### 도우미")
            lines.append(turn.text)
        }

        return BuildResult(body: lines.joined(separator: "\n") + "\n", itemUIDs: [])
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
        return formatAnchorLine(uid: uid, src: relativePath(from: noteFolder, to: scope.fileURL),
                                 loc: locator, state: initial)
    }

    /// 앵커 줄 렌더링(§3.3) — 알려진 키 8개 고정 순서 + `extraTokens`(미지 키 보존, `StudyNoteParser`가
    /// 채점 재작성 시 원래 있던 키를 그대로 뒤에 붙여 넘긴다). 새로 만든 항목은 `extraTokens` 없음.
    static func formatAnchorLine(uid: UUID, src: String, loc: StudyLocator, state: StudyReviewState, extraTokens: [String] = []) -> String {
        let ease = String(format: "%.2f", state.ease)
        var tokens = [
            "item=\(uid.uuidString)", "src=\(src)", "loc=\(anchorLoc(loc))",
            "due=\(dayFormatter.string(from: state.due))", "ivl=\(state.interval)",
            "ease=\(ease)", "reps=\(state.reps)", "lapses=\(state.lapses)"
        ]
        tokens.append(contentsOf: extraTokens)
        return "<!-- study " + tokens.joined(separator: " ") + " -->"
    }

    // MARK: - 위치 표기 변환(앵커용 `p12`/`l345`/`-` · 본문 인용용 `[[p12]]`, §3.3·O1)

    static func anchorLoc(_ locator: StudyLocator) -> String {
        switch locator {
        case .page(let n): return "p\(n)"
        case .pageRange(let a, let b): return "p\(a)-\(b)"
        case .line(let n): return "l\(n)"
        case .unknown: return "-"
        }
    }

    /// `anchorLoc(_:)`의 역변환 — `StudyNoteParser`가 앵커 줄을 읽어들일 때 쓴다. 알 수 없는
    /// 형식이면 nil(파일 손상·수기 편집 대응, §3.3 "위반 줄은 건너뛰고 경고 1건").
    static func parseAnchorLoc(_ s: String) -> StudyLocator? {
        if s == "-" { return .unknown }
        if s.hasPrefix("p") {
            let rest = s.dropFirst()
            if let dash = rest.firstIndex(of: "-") {
                guard let a = Int(rest[rest.startIndex..<dash]), let b = Int(rest[rest.index(after: dash)...]) else { return nil }
                return .pageRange(a, b)
            }
            guard let n = Int(rest) else { return nil }
            return .page(n)
        }
        if s.hasPrefix("l") {
            guard let n = Int(s.dropFirst()) else { return nil }
            return .line(n)
        }
        return nil
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

    /// 앵커 `due=` 값 파싱(`StudyNoteParser` 전용) — `dayFormatter`와 동일 규칙.
    static func parseDay(_ s: String) -> Date? { dayFormatter.date(from: s) }
}
