import Foundation

/// AI가 돌려준 텍스트(한 청크 분량)를 카드·문제 항목으로 해석한다(출력 계약 O1~O4).
/// 순수 함수 — 재요청(O5)·다중 청크 누적(O6)은 이 타입 밖(`StudyService`)의 몫이다.
enum StudyOutputParser {

    struct CardParseResult: Equatable {
        let cards: [StudyCard]
        /// 청크 밖 위치를 인용했거나 형식이 깨진 태그 수(§5.3·O4) — `.unknown`으로 강등된
        /// 항목은 폐기되지 않고 남지만, 이 값으로 "유효 인용 k/n" 표시에 쓴다.
        let invalidCitations: Int
    }

    struct QuestionParseResult: Equatable {
        let questions: [StudyQuestion]
        let invalidCitations: Int
    }

    // MARK: - 카드

    /// - Parameters:
    ///   - text: AI 응답 원문(이 청크 분량만).
    ///   - chunk: 이 응답을 만든 청크 — `coveredLocators`로 인용 검증(O4), 원문 대조로 발췌 검증.
    ///   - maxCount: 채택할 최대 개수(§O6 `ceil(N/C)`, 넘는 만큼은 앞에서부터 N개만 남기고 폐기).
    static func parseCards(_ text: String, chunk: StudyChunk, maxCount: Int) -> CardParseResult {
        var invalidCitations = 0
        var cards: [StudyCard] = []

        for block in blocks(in: text) {
            guard let headerLine = block.first, headerLine.hasPrefix("### [카드] ") else { continue }
            let rawTitle = String(headerLine.dropFirst("### [카드] ".count))
                .trimmingCharacters(in: .whitespaces)
            guard !rawTitle.isEmpty else { continue } // O2: 제목 필수.
            let title = String(rawTitle.prefix(80)) // O3.

            let bullets = block.dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .prefix(3) // O3: 4번째부터 폐기.
                .map { String($0.dropFirst(2).trimmingCharacters(in: .whitespaces).prefix(120)) } // O3.
            guard !bullets.isEmpty else { continue } // O2: 불릿 ≥1 필수.

            guard let evidenceLine = block.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("> 근거:") }),
                  let evidence = parseEvidence(evidenceLine, coveredLocators: chunk.coveredLocators)
            else { continue } // O2: 근거 필수.
            if evidence.isInvalidCitation { invalidCitations += 1 }

            let quote = String(evidence.quote.prefix(200)) // O3.
            cards.append(StudyCard(
                title: title,
                bullets: bullets,
                locator: evidence.locator,
                quote: quote,
                unverifiedQuote: !chunk.body.contains(quote)
            ))
        }

        return CardParseResult(cards: capAndDedupe(cards, by: \.title, maxCount: maxCount), invalidCitations: invalidCitations)
    }

    // MARK: - 문제

    static func parseQuestions(_ text: String, chunk: StudyChunk, maxCount: Int) -> QuestionParseResult {
        var invalidCitations = 0
        var questions: [StudyQuestion] = []

        for block in blocks(in: text) {
            guard let headerLine = block.first, headerLine.hasPrefix("### [문제"),
                  let bracketClose = headerLine.range(of: "] ")
            else { continue }
            let rawTitle = String(headerLine[bracketClose.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !rawTitle.isEmpty else { continue } // O2.
            let title = String(rawTitle.prefix(80)) // O3.

            let body = block.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }

            guard let type = firstValue(in: body, afterPrefix: "type:"), !type.isEmpty else { continue } // O2.
            guard let prompt = firstValue(in: body, afterPrefix: "Q:"), !prompt.isEmpty else { continue } // O2.
            guard let answer = firstValue(in: body, afterPrefix: "A:"), !answer.isEmpty else { continue } // O2.
            guard let explanationRaw = firstValue(in: body, afterPrefix: "해설:"), !explanationRaw.isEmpty else { continue } // O2.
            let explanation = String(explanationRaw.prefix(600)) // O3.

            let options = body
                .filter(isOptionLine)
                .map { line -> String in
                    let closeParen = line.firstIndex(of: ")")!
                    return String(line[line.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
                }
            if type == "mcq" {
                guard (3...5).contains(options.count) else { continue } // O2: mcq는 보기 3~5개 필수.
            }

            guard let evidenceLine = body.first(where: { $0.hasPrefix("> 근거:") }),
                  let evidence = parseEvidence(evidenceLine, coveredLocators: chunk.coveredLocators)
            else { continue } // O2.
            if evidence.isInvalidCitation { invalidCitations += 1 }

            let quote = String(evidence.quote.prefix(200)) // O3.
            questions.append(StudyQuestion(
                title: title,
                type: type,
                prompt: prompt,
                options: options,
                answer: answer,
                explanation: explanation,
                locator: evidence.locator,
                quote: quote,
                unverifiedQuote: !chunk.body.contains(quote)
            ))
        }

        return QuestionParseResult(questions: capAndDedupe(questions, by: \.title, maxCount: maxCount), invalidCitations: invalidCitations)
    }

    // MARK: - 공통: 블록 분리

    /// `### ` 줄로 시작하는 블록만 모은다. 그 앞의 잡담(서문)은 버리고, 각 블록의 첫 줄은
    /// 헤더(`### …`) 그대로, 이후 줄은 본문이다 — 헤더 문법 검증은 호출부(카드/문제별)가 한다.
    private static func blocks(in text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") {
                if !current.isEmpty { result.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func firstValue(in lines: [String], afterPrefix prefix: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func isOptionLine(_ trimmed: String) -> Bool {
        guard let closeParen = trimmed.firstIndex(of: ")") else { return false }
        let digits = trimmed[trimmed.startIndex..<closeParen]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// 중복 제목 폐기(먼저 나온 것을 남긴다) 후 §O6 상한(`maxCount`)으로 자른다.
    private static func capAndDedupe<T>(_ items: [T], by title: (T) -> String, maxCount: Int) -> [T] {
        var seenTitles = Set<String>()
        var deduped: [T] = []
        for item in items {
            let key = title(item).trimmingCharacters(in: .whitespaces).lowercased()
            guard !seenTitles.contains(key) else { continue }
            seenTitles.insert(key)
            deduped.append(item)
        }
        return Array(deduped.prefix(max(0, maxCount)))
    }

    // MARK: - 공통: 근거 줄(`> 근거: [[loc]] "발췌"`) 파싱

    private struct Evidence {
        let locator: StudyLocator
        let quote: String
        /// 태그가 있었는데(청크 밖이거나 형식이 깨져) `.unknown`으로 강등됐으면 true.
        /// 애초에 태그가 없거나 `[[?]]`(의도적 위치 불명)면 false.
        let isInvalidCitation: Bool
    }

    private static func parseEvidence(_ line: String, coveredLocators: [StudyLocator]) -> Evidence? {
        guard let quote = extractQuotedText(from: line) else { return nil } // O2: 발췌 필수.

        guard let tagInner = extractBracketedTag(from: line) else {
            return Evidence(locator: .unknown, quote: quote, isInvalidCitation: false)
        }
        guard let parsed = parseLocatorTag(tagInner) else {
            return Evidence(locator: .unknown, quote: quote, isInvalidCitation: true) // 형식 깨짐.
        }
        if parsed == .unknown {
            return Evidence(locator: .unknown, quote: quote, isInvalidCitation: false)
        }
        if coveredLocators.contains(parsed) {
            return Evidence(locator: parsed, quote: quote, isInvalidCitation: false)
        }
        return Evidence(locator: .unknown, quote: quote, isInvalidCitation: true) // 청크 밖 인용(§5.3).
    }

    private static func extractQuotedText(from line: String) -> String? {
        guard let first = line.firstIndex(of: "\""),
              let last = line[line.index(after: first)...].firstIndex(of: "\"")
        else { return nil }
        let content = String(line[line.index(after: first)..<last]).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func extractBracketedTag(from line: String) -> String? {
        guard let open = line.range(of: "[["),
              let close = line.range(of: "]]", range: open.upperBound..<line.endIndex)
        else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    /// `StudyChunker.tagString(for:)`의 역함수 — `[[…]]` 안쪽 내용만 받는다.
    private static func parseLocatorTag(_ inner: String) -> StudyLocator? {
        if inner == "?" { return .unknown }
        if inner.hasPrefix("p") {
            let rest = inner.dropFirst()
            if let dash = rest.firstIndex(of: "-") {
                guard let a = Int(rest[rest.startIndex..<dash]), let b = Int(rest[rest.index(after: dash)...])
                else { return nil }
                return .pageRange(a, b)
            }
            guard let n = Int(rest) else { return nil }
            return .page(n)
        }
        if inner.hasPrefix("l"), let n = Int(inner.dropFirst()) {
            return .line(n)
        }
        if inner.hasPrefix("s"), let n = Int(inner.dropFirst()) {
            return .section(n)
        }
        return nil
    }
}
