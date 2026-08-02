import Foundation
import PDFKit

/// 교재 파일에서 목차(장 목록 + 총 분량)를 뽑는다 — 진도 관리의 분모를 정하는 부품
/// (설계 `2026-08-02-study-progress-design.md` §목차 추출).
///
/// 종류별로 셀 수 있는 단위가 다르다: PDF는 쪽(`outlineRoot`), 마크다운/텍스트는 줄(헤딩),
/// 오피스는 변환된 글의 구간 번호(`StudySourceLoader.labeledSections` 재사용). 목차 정보가
/// 없는 교재(스캔 PDF·헤딩 없는 글)는 **"전체" 한 장짜리 목차**로 돌려준다 — 그 상태에서도
/// 쪽 단위 진도는 볼 수 있고, 사용자가 장을 직접 추가하면 그때부터 진짜 목차가 된다
/// (레고 결정 2026-08-02: "c + b").
///
/// 파일을 읽는 부분(PDF·텍스트)만 IO를 하고 나머지는 순수 함수다.
enum StudyOutlineExtractor {

    /// 목차가 아예 없을 때 쓰는 장 이름.
    static let wholeChapterTitle = "전체"
    /// 첫 장이 1보다 뒤에서 시작할 때 앞부분을 담는 장 이름.
    static let prefaceTitle = "머리말"

    // MARK: - 공통 조립(순수) — 이 파일의 핵심

    /// `(제목, 시작 위치)` 목록과 총 분량으로 장 배열을 만든다.
    ///
    /// - 각 장의 끝은 **다음 장 시작 − 1**, 마지막 장은 `total`.
    /// - 깨진 목차 방어: 시작이 1보다 작거나 `total`을 넘거나 **앞 장보다 뒤로 가지 않는**
    ///   항목은 버린다(PDF 목차에 실제로 이런 항목이 섞여 있다).
    /// - 첫 장이 1보다 뒤에서 시작하면 앞부분을 "머리말" 장으로 채운다 — 안 그러면 그
    ///   분량이 어느 장에도 안 잡혀 진도 분모만 늘어난다.
    /// - 쓸 수 있는 항목이 하나도 없으면 "전체" 한 장(1...total).
    static func chapters(from entries: [(title: String, start: Int)], total: Int) -> [StudyOutlineChapter] {
        guard total > 0 else { return [] }

        var kept: [(title: String, start: Int)] = []
        for entry in entries {
            guard entry.start >= 1, entry.start <= total else { continue }
            if let last = kept.last, entry.start <= last.start { continue }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            kept.append((title: title.isEmpty ? "제목 없음" : title, start: entry.start))
        }

        guard !kept.isEmpty else {
            return [StudyOutlineChapter(no: 1, title: wholeChapterTitle, start: 1, end: total)]
        }
        if kept[0].start > 1 {
            kept.insert((title: prefaceTitle, start: 1), at: 0)
        }

        return kept.enumerated().map { index, entry in
            let end = index + 1 < kept.count ? kept[index + 1].start - 1 : total
            return StudyOutlineChapter(no: index + 1, title: entry.title, start: entry.start, end: max(end, entry.start))
        }
    }

    // MARK: - PDF(쪽 단위)

    /// 목차를 어디서 얻었는지 — 화면이 사용자에게 "무엇을 근거로 만든 목차인지" 알려주고,
    /// 쪽번호 보정(`suggestedOffset`)을 물어볼지 말지 정하는 데 쓴다.
    enum Source: Equatable {
        /// PDF 안에 들어 있는 목차 데이터(영문 학술서 등). 쪽 어긋남이 없다.
        case embedded
        /// 목차 페이지에 **글자로** 적힌 차례를 읽어낸 것 — 한국 교재의 주 경로.
        case tocText
        /// 목차를 못 찾아 "전체 N쪽" 한 장으로 둔 것.
        case fallback
    }

    struct PDFOutlineResult {
        let outline: StudyOutline
        let source: Source
        /// 목차에 인쇄된 쪽번호에 더해야 실제 PDF 장 번호가 되는 값(글자 목차일 때만 의미 있음).
        let pageOffset: Int
        /// 글자 목차 원본(사용자가 보정값을 바꾸면 이걸로 다시 조립한다).
        let tocEntries: [StudyTOCTextParser.Entry]
    }

    /// PDF 목차. 내장 목차 → 목차 페이지 글자 → "전체 한 장" 순으로 시도한다.
    static func fromPDF(url: URL) -> PDFOutlineResult? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        return fromPDF(document: doc)
    }

    static func fromPDF(document doc: PDFDocument) -> PDFOutlineResult {
        let embedded = topLevelOutlineEntries(of: doc)
        if !embedded.isEmpty {
            return PDFOutlineResult(
                outline: StudyOutline(unit: .page, total: doc.pageCount,
                                      chapters: chapters(from: embedded, total: doc.pageCount)),
                source: .embedded, pageOffset: 0, tocEntries: [])
        }

        let tocEntries = textTOCEntries(of: doc)
        if !tocEntries.isEmpty {
            let offset = estimatePageOffset(document: doc, entries: tocEntries)
            return PDFOutlineResult(
                outline: outline(fromTOCEntries: tocEntries, offset: offset, pageCount: doc.pageCount),
                source: .tocText, pageOffset: offset, tocEntries: tocEntries)
        }

        return PDFOutlineResult(
            outline: StudyOutline(unit: .page, total: doc.pageCount,
                                  chapters: chapters(from: [], total: doc.pageCount)),
            source: .fallback, pageOffset: 0, tocEntries: [])
    }

    /// 글자 목차 + 보정값 → 목차. 사용자가 보정값을 ±로 고칠 때마다 이걸 다시 부른다.
    static func outline(fromTOCEntries entries: [StudyTOCTextParser.Entry],
                        offset: Int, pageCount: Int) -> StudyOutline {
        let shifted = entries.map { (title: $0.title, start: $0.printedPage + offset) }
        return StudyOutline(unit: .page, total: pageCount,
                            chapters: chapters(from: shifted, total: pageCount))
    }

    /// 앞쪽 장들의 글자에서 목차를 읽는다(§`StudyTOCTextParser`).
    static func textTOCEntries(of doc: PDFDocument) -> [StudyTOCTextParser.Entry] {
        let limit = min(StudyTOCTextParser.searchPageLimit, doc.pageCount)
        let texts = (0..<limit).map { doc.page(at: $0)?.string ?? "" }
        return StudyTOCTextParser.entries(fromPageTexts: texts)
    }

    // MARK: - 쪽번호 보정값 추정(실측: 목차의 "74쪽" = PDF 73번째 장)

    /// 목차 제목 몇 개를 본문에서 찾아 "PDF 장 번호 − 인쇄 쪽번호"의 **최빈값**을 고른다.
    /// 과목 표지 등에 제목이 한 번 더 나와 엉뚱한 값이 섞이므로, 여러 항목에서 같은 값이
    /// 두 번 이상 나올 때만 채택한다(안 그러면 0 — 사용자가 화면에서 직접 맞춘다).
    static func estimatePageOffset(document doc: PDFDocument,
                                   entries: [StudyTOCTextParser.Entry],
                                   probeLimit: Int = 6) -> Int {
        let probes = spreadSample(entries, count: probeLimit)
        var tally: [Int: Int] = [:]
        for probe in probes {
            let needle = searchNeedle(from: probe.title)
            guard needle.count >= 4 else { continue }
            // 같은 장에서 여러 번 맞아도 한 번으로 센다(표지의 소목차가 최빈값을 흔들지 않게).
            var pages = Set<Int>()
            for selection in doc.findString(needle, withOptions: []) {
                guard let page = selection.pages.first else { continue }
                let index = doc.index(for: page)
                guard index != NSNotFound else { continue }
                pages.insert(index + 1)
            }
            for page in pages {
                let offset = page - probe.printedPage
                guard probe.printedPage + offset >= 1, probe.printedPage + offset <= doc.pageCount else { continue }
                tally[offset, default: 0] += 1
            }
        }
        // 최빈값 — 같은 표를 얻으면 0에 가까운 쪽(=표지가 적게 붙은 쪽)을 고른다.
        let best = tally.filter { $0.value >= 2 }
            .max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : abs(lhs.key) > abs(rhs.key)
            }
        return best?.key ?? 0
    }

    /// 앞뒤로 치우치지 않게 목록 전체에서 고르게 뽑는다(앞쪽만 보면 표지 근처라 잘 틀린다).
    static func spreadSample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        guard items.count > count else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[min(items.count - 1, Int(Double($0) * step))] }
    }

    /// 검색어 다듬기 — 목차 번호("1.1.1.")와 괄호 보충설명은 본문 제목에 없을 수 있어 떼어낸다.
    static func searchNeedle(from title: String) -> String {
        var text = title
        if let range = text.range(of: #"^[0-9]+(\.[0-9]+)*\.?\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if let parenthesis = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<parenthesis])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `outlineRoot`의 **최상위 자식만** 훑는다(1차 범위 — 절 단위 중첩은 후속).
    /// 목적지는 `destination` → 없으면 `PDFActionGoTo`(둘 다 실제 PDF에서 쓰인다).
    static func topLevelOutlineEntries(of doc: PDFDocument) -> [(title: String, start: Int)] {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else { return [] }
        var entries: [(title: String, start: Int)] = []
        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index) else { continue }
            guard let page = destinationPage(of: child) else { continue }
            let pageIndex = doc.index(for: page)
            guard pageIndex != NSNotFound, pageIndex >= 0 else { continue }
            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append((title: label, start: pageIndex + 1))
        }
        return entries
    }

    private static func destinationPage(of item: PDFOutline) -> PDFPage? {
        if let page = item.destination?.page { return page }
        if let goTo = item.action as? PDFActionGoTo { return goTo.destination.page }
        return nil
    }

    // MARK: - 마크다운/텍스트(줄 단위)

    /// 헤딩(`#`)을 장으로, 총 분량은 줄 수. 헤딩이 없으면 "전체" 한 장.
    static func fromMarkdown(content: String) -> StudyOutline {
        let lineCount = content.components(separatedBy: .newlines).count
        guard lineCount > 0 else { return StudyOutline(unit: .line, total: 0, chapters: []) }
        let entries = TOCBuilder.extractHeadings(from: content)
            .map { (title: $0.text, start: $0.lineNumber) }
        return StudyOutline(unit: .line, total: lineCount,
                            chapters: chapters(from: entries, total: lineCount))
    }

    // MARK: - 오피스(구간 단위)

    /// kordoc이 변환한 글을 제목 경계로 나눈 구간 하나 = 장 하나. 원본 파일의 쪽·줄은 끝내
    /// 알 수 없으므로(§5.2) 구간 번호 자체가 위치이자 분량이다.
    static func fromOfficeBody(_ body: String) -> StudyOutline {
        let labeled = StudySourceLoader.labeledSections(from: body)
        guard !labeled.isEmpty else { return StudyOutline(unit: .section, total: 0, chapters: []) }
        let chapters = labeled.map {
            StudyOutlineChapter(no: $0.index, title: $0.title, start: $0.index, end: $0.index)
        }
        return StudyOutline(unit: .section, total: labeled.count, chapters: chapters)
    }
}
