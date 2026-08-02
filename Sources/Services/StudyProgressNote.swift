import Foundation
import Yams

/// 교재 한 권의 **진도 노트**(마크다운) 읽기·쓰기. 전부 순수 함수 — 디스크 IO는 호출부
/// (`AppState+StudyProgress`)가 한다(카드·문제 노트와 같은 어법).
///
/// 진도의 진실의 출처는 설정 파일이 아니라 **이 노트 파일**이다(§3.1과 같은 원칙):
/// 옵시디언에서 그대로 보이고, 백업되고, 사용자가 목차를 손으로 고칠 수 있다
/// (레고 결정 2026-08-02 "2-b 직접 입력").
///
/// ```markdown
/// ---
/// study_progress_id: <uuid>
/// study_source: "%EA%B5%90%EC%9E%AC.pdf"
/// study_source_kind: pdf
/// study_outline_unit: page
/// study_total: 562
/// study_page_offset: -1
/// study_updated: 2026-08-02
/// ---
///
/// # 진도: 미디어교육사 교재.pdf
///
/// <!-- outline no=1 start=1 end=6 read=no -->
/// ## 머리말 (1~6쪽)
/// ```
enum StudyProgressNote {

    /// 진도 노트를 읽어낸 결과.
    struct Parsed: Equatable {
        let progressID: UUID
        /// 교재 파일의 상대경로(percent-encoded, 노트 폴더 기준) — 카드 노트 `study_source`와 같은 규칙.
        let source: String
        let sourceKind: DocumentKind?
        let unit: StudyOutlineUnit
        let total: Int
        /// 목차에 인쇄된 쪽번호 + 이 값 = 실제 PDF 장 번호(글자 목차에서만 0이 아니다).
        let pageOffset: Int
        let chapters: [StudyOutlineChapter]

        var outline: StudyOutline { StudyOutline(unit: unit, total: total, chapters: chapters) }
    }

    /// 진도 노트를 담는 하위 폴더 이름(학습 폴더 밑).
    static let folderName = "진도"

    // MARK: - 쓰기

    /// 진도 노트 전문. 파일에 그대로 쓰면 된다(쓰기는 호출부 몫).
    static func build(
        outline: StudyOutline, sourceURL: URL, sourceKind: DocumentKind, noteFolder: URL,
        pageOffset: Int = 0, now: Date = Date(), makeUUID: () -> UUID = UUID.init
    ) -> String {
        let relative = StudyNoteWriter.relativePath(from: noteFolder, to: sourceURL)
        var lines = [
            "---",
            "study_progress_id: \(makeUUID().uuidString)",
            "study_source: \(CompanionNote.yamlQuoted(relative))",
            "study_source_kind: \(sourceKind.rawValue)",
            "study_outline_unit: \(outline.unit.rawValue)",
            "study_total: \(outline.total)",
            "study_page_offset: \(pageOffset)",
            "study_updated: \(StudyNoteWriter.formatDay(now))",
            "---",
            "",
            "# 진도: \(sourceURL.lastPathComponent)",
        ]
        for chapter in outline.chapters {
            lines.append("")
            lines.append(formatAnchorLine(chapter))
            lines.append(headingLine(chapter, unit: outline.unit))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 목차만 갈아끼운 새 본문 — `study_updated`도 함께 갱신한다. 읽음 표시는 **장 번호 기준으로
    /// 이어받는다**(목차를 다시 읽어도 이미 읽은 표시를 잃지 않게).
    static func replacingOutline(in content: String, with outline: StudyOutline,
                                 pageOffset: Int, now: Date = Date()) -> String? {
        guard let parsed = parse(content),
              let (yamlString, _) = CompanionNote.splitFrontmatter(content) else { return nil }
        let previousRead = Dictionary(uniqueKeysWithValues: parsed.chapters.map { ($0.no, ($0.read, $0.done)) })

        var frontmatterLines: [String] = []
        for line in yamlString.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("study_outline_unit:") {
                frontmatterLines.append("study_outline_unit: \(outline.unit.rawValue)")
            } else if trimmed.hasPrefix("study_total:") {
                frontmatterLines.append("study_total: \(outline.total)")
            } else if trimmed.hasPrefix("study_page_offset:") {
                frontmatterLines.append("study_page_offset: \(pageOffset)")
            } else if trimmed.hasPrefix("study_updated:") {
                frontmatterLines.append("study_updated: \(StudyNoteWriter.formatDay(now))")
            } else if !trimmed.isEmpty {
                frontmatterLines.append(line)
            }
        }
        if !frontmatterLines.contains(where: { $0.hasPrefix("study_page_offset:") }) {
            frontmatterLines.append("study_page_offset: \(pageOffset)")
        }

        var lines = ["---"] + frontmatterLines + ["---", "", firstHeading(in: content) ?? "# 진도"]
        for chapter in outline.chapters {
            var carried = chapter
            if let previous = previousRead[chapter.no] {
                carried.read = previous.0
                carried.done = previous.1
            }
            lines.append("")
            lines.append(formatAnchorLine(carried))
            lines.append(headingLine(carried, unit: outline.unit))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 장 하나의 읽음 표시만 바꾼 새 본문. 그 장 앵커를 못 찾으면 nil(파일에 아무것도 쓰지 않는다).
    static func replacingReadFlag(in content: String, chapterNo: Int, read: Bool,
                                  now: Date = Date()) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let index = lines.indices.first(where: { parseAnchorLine(lines[$0])?.no == chapterNo }),
              var chapter = parseAnchorLine(lines[index]) else { return nil }
        chapter.read = read
        chapter.done = read ? now : nil
        lines[index] = formatAnchorLine(chapter)
        return lines.joined(separator: "\n")
    }

    /// 장 하나를 손으로 더하는 경우(목차 없는 교재 — 레고 결정 2-b). 시작 위치 순서로 끼워 넣고
    /// 번호·끝 위치를 다시 매긴 목차를 돌려준다.
    static func inserting(title: String, start: Int, into outline: StudyOutline) -> StudyOutline {
        var entries = outline.chapters.map { (title: $0.title, start: $0.start, read: $0.read, done: $0.done) }
        entries.append((title: title, start: start, read: false, done: nil))
        entries.sort { $0.start < $1.start }

        var chapters: [StudyOutlineChapter] = []
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].start - 1 : outline.total
            guard entry.start >= 1, entry.start <= outline.total else { continue }
            chapters.append(StudyOutlineChapter(no: chapters.count + 1, title: entry.title,
                                                start: entry.start, end: max(end, entry.start),
                                                read: entry.read, done: entry.done))
        }
        return StudyOutline(unit: outline.unit, total: outline.total, chapters: chapters)
    }

    // MARK: - 읽기

    static func parse(_ content: String) -> Parsed? {
        guard let (yamlString, _) = CompanionNote.splitFrontmatter(content),
              let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any],
              let idString = yaml["study_progress_id"] as? String,
              let progressID = UUID(uuidString: idString),
              let source = yaml["study_source"] as? String,
              let unitString = yaml["study_outline_unit"] as? String,
              let unit = StudyOutlineUnit(rawValue: unitString)
        else { return nil }

        let total = intValue(yaml["study_total"]) ?? 0
        let pageOffset = intValue(yaml["study_page_offset"]) ?? 0
        let kind = (yaml["study_source_kind"] as? String).flatMap { DocumentKind(rawValue: $0) }

        let lines = content.components(separatedBy: "\n")
        var chapters: [StudyOutlineChapter] = []
        var seen = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard var chapter = parseAnchorLine(line), !seen.contains(chapter.no) else { continue }
            seen.insert(chapter.no)
            if index + 1 < lines.count, let title = title(fromHeading: lines[index + 1]) {
                chapter = StudyOutlineChapter(no: chapter.no, title: title, start: chapter.start,
                                              end: chapter.end, read: chapter.read, done: chapter.done,
                                              extraTokens: chapter.extraTokens)
            }
            chapters.append(chapter)
        }
        return Parsed(progressID: progressID, source: source, sourceKind: kind, unit: unit,
                      total: total, pageOffset: pageOffset,
                      chapters: chapters.sorted { $0.no < $1.no })
    }

    // MARK: - 앵커 한 줄

    /// `<!-- outline no=1 start=1 end=44 read=no done=2026-08-02 -->`
    /// 값에 공백을 넣지 않는 규칙은 카드·문제 앵커(§3.3)와 같다 — 그래서 제목은 앵커가 아니라
    /// 바로 다음 제목 줄에 둔다(사용자가 제목을 고쳐도 구조가 안 깨진다).
    static func formatAnchorLine(_ chapter: StudyOutlineChapter) -> String {
        var tokens = [
            "no=\(chapter.no)", "start=\(chapter.start)", "end=\(chapter.end)",
            "read=\(chapter.read ? "yes" : "no")",
        ]
        if let done = chapter.done {
            tokens.append("done=\(StudyNoteWriter.formatDay(done))")
        }
        tokens.append(contentsOf: chapter.extraTokens)
        return "<!-- outline " + tokens.joined(separator: " ") + " -->"
    }

    /// 제목은 여기서 알 수 없다(앵커에 없으므로) — 호출부가 다음 줄에서 채운다.
    static func parseAnchorLine(_ raw: String) -> StudyOutlineChapter? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- outline "), trimmed.hasSuffix("-->") else { return nil }
        let inner = String(trimmed.dropFirst("<!-- outline ".count).dropLast("-->".count))
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }

        let known: Set<String> = ["no", "start", "end", "read", "done"]
        var dict: [String: String] = [:]
        var extra: [String] = []
        for token in inner.split(separator: " ", omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: "=") else { return nil }
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            if known.contains(key) { dict[key] = value } else { extra.append(String(token)) }
        }
        guard let no = dict["no"].flatMap(Int.init), no >= 1,
              let start = dict["start"].flatMap(Int.init),
              let end = dict["end"].flatMap(Int.init)
        else { return nil }
        let read = dict["read"] == "yes"
        let done = dict["done"].flatMap(StudyNoteWriter.parseDay)
        return StudyOutlineChapter(no: no, title: "", start: start, end: end,
                                   read: read, done: done, extraTokens: extra)
    }

    // MARK: - 제목 줄

    static func headingLine(_ chapter: StudyOutlineChapter, unit: StudyOutlineUnit) -> String {
        "## \(chapter.title) (\(chapter.start)~\(chapter.end)\(unit.label))"
    }

    /// `## 머리말 (1~6쪽)` → `머리말`. 제목 줄이 아니면 nil.
    static func title(fromHeading line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        // 렌더링할 때 붙인 범위 꼬리표만 떼어낸다(맨 뒤 " (…)" 하나).
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            text = String(text[text.startIndex..<open.lowerBound])
        }
        return text.isEmpty ? nil : text
    }

    private static func firstHeading(in content: String) -> String? {
        content.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let text = any as? String { return Int(text) }
        return nil
    }

    // MARK: - 파일 이름

    /// 교재 파일 이름에서 진도 노트 파일 이름을 만든다(확장자만 `.md`로).
    static func fileName(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "진도" : base) + ".md"
    }
}
