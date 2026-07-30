import Foundation

/// 위키 문서 본문에서 링크를 뽑아내는 순수 함수(디스크 접근 없음). 코드 펜스·인라인 코드·
/// frontmatter는 마스킹 후 스캔해 예시 코드 안의 `[[...]]` 등을 링크로 오인하지 않는다.
enum WikiLinkExtractor {
    /// - Returns: 발견 순서(문서 내 등장 순)대로의 원본 링크 목록.
    static func links(in markdown: String) -> [WikiRawLink] {
        guard !markdown.isEmpty else { return [] }
        let masked = maskNonLinkRegions(markdown)
        var found: [(location: Int, link: WikiRawLink)] = []
        found.append(contentsOf: markdownLinks(in: masked))
        found.append(contentsOf: wikiLinksAndEmbeds(in: masked))
        return found.sorted { $0.location < $1.location }.map(\.link)
    }

    // MARK: - 마스킹(코드 펜스·인라인 코드·frontmatter)

    /// 코드/frontmatter 영역을 같은 길이의 공백(개행은 보존)으로 지운 사본을 돌려준다 —
    /// 그 안의 `[[...]]`·`[text](url)` 예시가 실제 링크로 잡히지 않게 한다.
    private static func maskNonLinkRegions(_ text: String) -> NSMutableString {
        let ns = NSMutableString(string: text)
        var ranges: [NSRange] = []
        if let fm = frontmatterRange(in: text) { ranges.append(fm) }
        ranges.append(contentsOf: matchRanges(of: Self.codeFencePattern, in: text))
        // 인라인 코드는 펜스 마스킹 뒤 다시 스캔(펜스 안 홑따옴표 잔재 방지) — 아래서 순차 적용.
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            blank(ns, range: range)
        }
        for range in matchRanges(of: Self.inlineCodePattern, in: ns as String).sorted(by: { $0.location > $1.location }) {
            blank(ns, range: range)
        }
        return ns
    }

    private static func blank(_ ns: NSMutableString, range: NSRange) {
        let sub = ns.substring(with: range) as NSString
        var replacement = ""
        replacement.reserveCapacity(sub.length)
        for i in 0..<sub.length {
            replacement.append(sub.character(at: i) == 10 ? "\n" : " ")
        }
        ns.replaceCharacters(in: range, with: replacement)
    }

    private static func frontmatterRange(in text: String) -> NSRange? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let ns = text as NSString
        let openLength = text.hasPrefix("---\r\n") ? 5 : 4
        guard ns.length > openLength else { return nil }
        let searchRange = NSRange(location: openLength, length: ns.length - openLength)
        guard let closing = try? NSRegularExpression(pattern: "^---[ \t]*$", options: [.anchorsMatchLines])
            .firstMatch(in: text, range: searchRange) else { return nil }
        return NSRange(location: 0, length: closing.range.location + closing.range.length)
    }

    private static func matchRanges(of regex: NSRegularExpression, in text: String) -> [NSRange] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    // MARK: - 마크다운 표준 링크 `[텍스트](경로)`

    private static func markdownLinks(in masked: NSMutableString) -> [(location: Int, link: WikiRawLink)] {
        let text = masked as String
        let ns = masked
        var results: [(Int, WikiRawLink)] = []
        let matches = Self.markdownLinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let target = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            guard isEligibleMarkdownTarget(target) else { continue }
            let displayRange = match.range(at: 1)
            let display = displayRange.length > 0 ? ns.substring(with: displayRange) : nil
            results.append((match.range.location,
                            WikiRawLink(kind: .markdown, rawTarget: target, displayText: display)))
        }
        return results
    }

    private static func isEligibleMarkdownTarget(_ target: String) -> Bool {
        guard !target.isEmpty else { return false }
        let lowered = target.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") {
            return false
        }
        if target.hasPrefix("#") { return false }   // 앵커전용
        return true
    }

    // MARK: - 위키링크·임베드 `[[페이지]]` / `[[페이지|표시]]` / `![[페이지]]`

    /// `MarkdownRenderer.wikiLinkPattern`과 동일 문법 — 렌더러의 실제 내비게이션 동작과
    /// 일치시키기 위해 파이프 뒤쪽(group 3)을 대상(href)으로, 앞쪽(group 2)을 표시 텍스트로 쓴다.
    private static func wikiLinksAndEmbeds(in masked: NSMutableString) -> [(location: Int, link: WikiRawLink)] {
        let text = masked as String
        let ns = masked
        var results: [(Int, WikiRawLink)] = []
        let matches = Self.wikiLinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let isEmbed = ns.substring(with: match.range(at: 1)) == "!"
            let aliasRange = match.range(at: 2)
            let alias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            let target = ns.substring(with: match.range(at: 3))
            guard !target.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            results.append((match.range.location,
                            WikiRawLink(kind: isEmbed ? .embed : .wiki, rawTarget: target, displayText: alias)))
        }
        return results
    }

    // MARK: - 정규식(1회 컴파일)

    private static let markdownLinkPattern = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]]*)\]\(([^)]+)\)"#, options: [])
    private static let wikiLinkPattern = try! NSRegularExpression(
        pattern: #"(!?)\[\[(?:(.+?)\|)?(.+?)\]\]"#, options: [])
    private static let codeFencePattern = try! NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: [])
    private static let inlineCodePattern = try! NSRegularExpression(
        pattern: "`[^`\\n]+`", options: [])
}
