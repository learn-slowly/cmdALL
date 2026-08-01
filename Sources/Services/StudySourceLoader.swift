import Foundation
import PDFKit

/// `StudyScope`(사용자가 고른 학습 범위)를 실제로 읽어 위치 태그가 붙은 조각
/// (`StudySegment`) 배열로 만든다(설계 §5).
///
/// 위치가 필요한 PDF·마크다운/텍스트는 `ContentExtractor`(색인용 — 페이지·줄 경계를
/// 개행으로 이어붙여 잃어버린다, §5.4 각주)를 재사용하지 않고 이 actor가 직접 읽는다.
/// office는 원본 안에서의 위치를 알 수 없으므로 근거 위치는 항상 `.unknown`이지만,
/// 변환된 글 자체는 제목(헤딩) 단위로 부분 선택을 받을 수 있다(§5.2 I3, 2026-08-01).
/// 이미지는 나눌 단위가 없어 파일 전체만 가능하다. 둘 다 기존 변환기(kordoc·`OCRService`)를
/// 그대로 재사용한다.
///
/// 학습도우미는 범위(챕터) 선택이 항상 필수라(Q1 pre-mortem 1) 입력이 이미 작다 —
/// 검색 색인의 "스캔 PDF 앞 30쪽까지만"·"OCR 기본 OFF" 같은 속도 제한을 여기선 두지
/// 않는다(2026-08-01 코드 조사 결론, `docs/worklog.md` 참고): 글자 레이어가 없는 PDF
/// 쪽은 항상 OCR로 보강 시도하고, 이미지 범위는 사용자가 "이 사진으로 학습하겠다"고
/// 직접 고른 것이므로 전역 "사진 속 글자 검색" 설정과 무관하게 항상 OCR을 시도한다.
actor StudySourceLoader {
    private let kordoc: KordocService

    init(kordoc: KordocService) {
        self.kordoc = kordoc
    }

    func segments(for scope: StudyScope) async -> [StudySegment] {
        switch scope.kind {
        case .pdf:
            return Self.pdfSegments(url: scope.fileURL, range: scope.range)
        case .markdown:
            return Self.textSegments(url: scope.fileURL, range: scope.range)
        case .office:
            guard let body = try? await kordoc.markdown(for: scope.fileURL) else { return [] }
            return Self.officeSegments(body: body, range: scope.range)
        case .image:
            guard let cgImage = OCRService.loadCGImage(from: scope.fileURL),
                  let text = OCRService.recognizeText(in: cgImage)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return [] }
            return [StudySegment(text: text, locator: .unknown)]
        case .media, .quickLook:
            // §5.2: media는 짝꿍 노트가 있으면 마크다운으로 취급하지만, 그 리다이렉트(원본
            // 미디어 URL → 짝꿍 .md URL로 스코프 자체를 바꾸는 것)는 스코프를 구성하는
            // 화면(예정)의 책임이다 — 이 시점엔 이미 kind가 확정된 뒤라 여기서 할 수 없다.
            return []
        }
    }

    // MARK: - PDF(쪽 단위, 빈 쪽은 OCR 보강 — §5.2)

    private static func pdfSegments(url: URL, range: StudyScopeRange) -> [StudySegment] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return [] }
        guard let (lo, hi) = pageBounds(range: range, pageCount: doc.pageCount) else { return [] }

        var segments: [StudySegment] = []
        for pageIndex in (lo - 1)...(hi - 1) {
            guard let page = doc.page(at: pageIndex) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                text = OCRService.recognizeText(in: page)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            guard !text.isEmpty else { continue } // 그래도 비면 스킵(§5.2).
            segments.append(StudySegment(text: text, locator: .page(pageIndex + 1)))
        }
        return segments
    }

    private static func pageBounds(range: StudyScopeRange, pageCount: Int) -> (Int, Int)? {
        switch range {
        case .pageRange(let a, let b):
            let lo = max(1, min(a, b))
            let hi = min(pageCount, max(a, b))
            return lo <= hi ? (lo, hi) : nil
        case .wholeFile:
            return (1, pageCount)
        case .lineRange, .sectionRange:
            return nil // PDF는 줄·구간 범위 개념이 없다 — 잘못 짝지어진 범위는 조각 0개.
        }
    }

    // MARK: - 오피스(변환된 글을 제목 경계로 나눈 "구간" 단위 — §5.2 I3)

    /// office는 원본 파일 안에서의 위치(쪽·줄)를 알 방법이 없다 — kordoc이 그 정보를
    /// 주지 않는다. 대신 변환된 글 자체를 마크다운/텍스트와 같은 방식으로 제목(헤딩)
    /// 경계에서 나눠 "N번째 구간"이라는 단위를 만들고, 그 구간 단위로 부분 선택을 받는다.
    /// 위치는 여전히 `.unknown`(원본 몇 쪽인지는 끝내 모른다).
    static func officeSegments(body: String, range: StudyScopeRange) -> [StudySegment] {
        let sections = headingSections(from: body)
        guard !sections.isEmpty else { return [] }
        guard let (lo, hi) = sectionBounds(range: range, sectionCount: sections.count) else { return [] }
        return sections[(lo - 1)...(hi - 1)].map { StudySegment(text: $0, locator: .unknown) }
    }

    /// 헤딩 경계로 나눈 구간 본문 목록(순서대로, 빈 구간은 제외) — 텍스트 파일 세그먼트
    /// 분할(`textSegments`)과 같은 알고리즘이되, 여긴 원본 파일이 아니라 kordoc이 만든
    /// 글 자체를 나누는 것이라 줄 번호를 위치로 쓰지 않는다.
    static func headingSections(from content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        let headingLines = TOCBuilder.extractHeadings(from: content)
            .map(\.lineNumber)
            .filter { $0 > 1 }
        let starts = ([1] + headingLines).sorted()

        var sections: [String] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : lines.count
            guard start <= end else { continue }
            let body = lines[(start - 1)...(end - 1)].joined(separator: "\n")
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sections.append(trimmed)
        }
        return sections
    }

    static func sectionBounds(range: StudyScopeRange, sectionCount: Int) -> (Int, Int)? {
        switch range {
        case .sectionRange(let a, let b):
            let lo = max(1, min(a, b))
            let hi = min(sectionCount, max(a, b))
            return lo <= hi ? (lo, hi) : nil
        case .wholeFile:
            return (1, sectionCount)
        case .pageRange, .lineRange:
            return nil // 오피스는 쪽·줄 범위 개념이 없다.
        }
    }

    // MARK: - 마크다운/텍스트(줄 단위 + 헤딩 경계 — §5.2)

    private static func textSegments(url: URL, range: StudyScopeRange) -> [StudySegment] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)
        guard let (lo, hi) = lineBounds(range: range, lineCount: lines.count) else { return [] }

        // 헤딩 경계에서 나눈다(기존 TOC 추출기 재사용, §5.4) — 범위 시작줄보다 뒤·범위
        // 끝줄 이내인 헤딩만 새 조각의 시작점이 된다. 시작줄(lo) 자체는 헤딩이든 아니든
        // 항상 첫 조각의 시작점이다(그 앞부분 헤딩은 선택 범위 밖이라 무관).
        let headingLines = TOCBuilder.extractHeadings(from: content)
            .map(\.lineNumber)
            .filter { $0 > lo && $0 <= hi }
        let starts = ([lo] + headingLines).sorted()

        var segments: [StudySegment] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : hi
            guard start <= end else { continue }
            let body = lines[(start - 1)...(end - 1)].joined(separator: "\n")
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            segments.append(StudySegment(text: trimmed, locator: .line(start)))
        }
        return segments
    }

    private static func lineBounds(range: StudyScopeRange, lineCount: Int) -> (Int, Int)? {
        guard lineCount > 0 else { return nil }
        switch range {
        case .lineRange(let a, let b):
            let lo = max(1, min(a, b))
            let hi = min(lineCount, max(a, b))
            return lo <= hi ? (lo, hi) : nil
        case .wholeFile:
            return (1, lineCount)
        case .pageRange, .sectionRange:
            return nil // 마크다운·텍스트는 쪽·구간 범위 개념이 없다.
        }
    }
}
