import Foundation

/// 학습 노트의 근거 태그(`> 근거: [[p9]] "…"`) 클릭을 **원본 자료의 그 위치**로 잇는 순수 헬퍼.
///
/// 배경(레고 2026-08-01 "이게 링크가 안 걸리네?"): 근거 태그는 겉모습이 위키링크(`[[…]]`)라
/// 미리보기에서 링크로 그려지지만, 실제로는 "p9 = 9쪽"이라는 **위치 표시**지 노트 이름이 아니다.
/// 그래서 노트 찾기에 실패해 아무 데도 가지 못했다. 이제 태그를 위치로 해석하고, 같은 노트의
/// 항목 앵커(`<!-- study … src=… loc=… -->`)에 적힌 원본 파일 경로를 찾아 그 쪽/줄로 연다.
///
/// 전부 순수 함수 — 디스크 접근·열기는 호출부(`AppState+Navigation`)가 한다.
enum StudySourceLink {

    /// `p9`·`p9-12`·`l345`·`?` 같은 근거 태그를 위치로. 노트 이름이면 nil.
    /// (앵커의 `-`(위치 불명)는 본문에선 `?`로 적힌다 — §`StudyNoteWriter.bracketTag`.)
    static func locator(fromTag tag: String) -> StudyLocator? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed == "?" { return .unknown }
        return StudyNoteWriter.parseAnchorLoc(trimmed)
    }

    /// 노트 본문에서 그 근거가 가리키는 원본 파일 경로(앵커 `src` 값, percent-encoded 상대경로).
    /// 위치가 정확히 같은 항목이 있으면 그 항목의 경로, 없으면 첫 항목의 경로를 쓴다
    /// (학습 노트 하나는 원본 파일 하나에서 만들어진다 — §3.3). 항목 앵커가 없으면
    /// frontmatter `study_source`로 넘어간다(대화 노트·수기 편집 대비).
    static func sourceRelativePath(for locator: StudyLocator, in noteContent: String) -> String? {
        let items = StudyNoteParser.parse(noteContent).items
        if let exact = items.first(where: { $0.loc == locator }) { return exact.src }
        if let first = items.first { return first.src }
        return frontmatterSource(in: noteContent)
    }

    /// frontmatter의 `study_source:` 값(따옴표 벗김). 없으면 nil.
    static func frontmatterSource(in noteContent: String) -> String? {
        guard let (yamlString, _) = CompanionNote.splitFrontmatter(noteContent) else { return nil }
        for line in yamlString.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("study_source:") else { continue }
            var value = String(trimmed.dropFirst("study_source:".count))
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 앵커 `src`(percent-encoded 상대경로) → 절대 URL. 노트가 있는 폴더 기준.
    static func sourceURL(relativePath: String, noteFolder: URL) -> URL? {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded).standardizedFileURL }
        // 폴더임을 명시하지 않으면 마지막 조각을 파일로 보고 한 단계 위에서 상대경로를 풀어버린다.
        let base = URL(fileURLWithPath: noteFolder.path, isDirectory: true)
        return URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
    }

    /// 위치에서 "몇 쪽"(PDF 점프용). 쪽 범위는 첫 쪽, 줄·구간·불명은 nil
    /// (구간은 한글·워드 변환본 기준이라 원본 파일에서 그 자리로 뛸 수 없다).
    static func page(of locator: StudyLocator) -> Int? {
        switch locator {
        case .page(let n): return n
        case .pageRange(let a, _): return a
        case .line, .section, .unknown: return nil
        }
    }

    /// 위치에서 "몇 줄"(텍스트 점프용). 그 외는 nil.
    static func line(of locator: StudyLocator) -> Int? {
        if case .line(let n) = locator { return n }
        return nil
    }
}
