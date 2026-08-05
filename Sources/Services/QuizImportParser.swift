import Foundation

/// 이미 만들어 둔 문제집 마크다운을 읽어 `StudyQuestion` 배열로 되돌린다(순수 함수 — 디스크 IO 없음).
///
/// 대상 형식은 "문제부 + 정답·해설부"가 나뉜 흔한 한국식 문제집 md다(레고의 미디어교육사 100제가 그 꼴).
/// 학습도우미가 새로 만드는 문제와 달리 **교재 원문 발췌(근거)가 없으므로** `quote`는 빈 문자열이고,
/// 위치는 해설의 `#page=NNN` 링크에서 가져온다.
///
/// ```markdown
/// ## A. 옳은 것 고르기 (1~18)
///
/// **1.** 발문
/// ① 보기1
/// ② 보기2
///
/// # 정답 · 해설
///
/// **1. ②** 해설 문장. [[교재.pdf#page=9|📖 p.009]]
/// ```
enum QuizImportParser {

    /// 동그라미 숫자 ①~⑮(1~15) — 보기가 다섯 개를 넘는 문제집도 있어 넉넉히 받는다.
    private static let circled = "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮"

    struct Result: Equatable {
        let questions: [StudyQuestion]
        /// 발문·보기는 찾았는데 정답을 못 찾은 번호(원본이 부실한 경우) — 호출부가 안내에 쓴다.
        let missingNumbers: [Int]
    }

    /// 정답부에서 뽑은 한 항목.
    private struct Answer {
        let index: Int          // 1-based 보기 번호
        let explanation: String
        let page: Int?
    }

    /// 문제부에서 뽑은 한 항목.
    private struct Stem {
        var section: String
        var prompt: String
        var options: [String]
    }

    static func parse(_ content: String) -> Result {
        let lines = content.components(separatedBy: "\n")
        let answerStart = answerSectionIndex(in: lines)
        let stems = parseStems(Array(lines[..<answerStart]))
        let answers = parseAnswers(Array(lines[answerStart...]))

        var questions: [StudyQuestion] = []
        var missing: [Int] = []
        for number in stems.keys.sorted() {
            guard let stem = stems[number], !stem.options.isEmpty else { continue }
            guard let answer = answers[number], answer.index >= 1, answer.index <= stem.options.count else {
                missing.append(number)
                continue
            }
            questions.append(StudyQuestion(
                title: title(from: stem.prompt, number: number),
                type: stem.section,
                prompt: stem.prompt,
                options: stem.options,
                answer: String(answer.index),
                explanation: answer.explanation,
                locator: answer.page.map { StudyLocator.page($0) } ?? .unknown,
                // 원본에 교재 원문 발췌가 없다 — 없는 근거를 지어내지 않는다(§"추정을 사실로 적지 않는다").
                quote: "",
                unverifiedQuote: false))
        }
        return Result(questions: questions, missingNumbers: missing)
    }

    // MARK: - 문제부

    /// `# 정답`·`## 정답 · 해설` 등 정답부가 시작하는 줄. 없으면 파일 끝(= 정답 0건).
    private static func answerSectionIndex(in lines: [String]) -> Int {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("정답") { return index }
        }
        return lines.count
    }

    private static func parseStems(_ lines: [String]) -> [Int: Stem] {
        var stems: [Int: Stem] = [:]
        var section = ""
        var current: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 섹션 머리글 — `# A. 옳은 것 고르기` / `## A. 옳은 것 고르기 (1~18)` 둘 다 받는다.
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty, !heading.hasPrefix("정답") {
                    section = sectionLabel(heading)
                    current = nil
                }
                continue
            }

            // 문항 시작 — `**12.** 발문`
            if let (number, rest) = questionHeader(trimmed) {
                stems[number] = Stem(section: section, prompt: rest, options: [])
                current = number
                continue
            }

            guard let number = current, var stem = stems[number] else { continue }

            // 보기 — 한 줄에 하나일 수도, `① 가  ② 나  ③ 다`처럼 붙어 있을 수도 있다.
            if let first = trimmed.first, circledIndex(first) == stem.options.count + 1 {
                stem.options.append(contentsOf: splitOptions(trimmed, startingAt: stem.options.count))
                stems[number] = stem
                continue
            }

            // 보기가 아직 없으면 발문이 여러 줄로 이어지는 중이다.
            if !trimmed.isEmpty, stem.options.isEmpty {
                stem.prompt = stem.prompt.isEmpty ? trimmed : stem.prompt + "\n" + trimmed
                stems[number] = stem
            }
        }
        return stems
    }

    /// `**12.** 발문` → (12, "발문"). 굵게 표시가 없는 `12. 발문`도 받는다.
    private static func questionHeader(_ line: String) -> (Int, String)? {
        var rest = Substring(line)
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix(".") else { return nil }
        rest = rest.dropFirst()
        // 정답부의 `**1. ②** …`가 문제부에 섞여 들어오면 문항 시작이 아니다.
        if let first = rest.trimmingCharacters(in: .whitespaces).first, circled.contains(first) { return nil }
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 한 줄에 붙어 있는 보기를 동그라미 숫자 앞에서 자른다.
    ///
    /// 자르는 자리는 **다음에 올 번호와 정확히 맞는** 동그라미 숫자뿐이다. 보기 문장 안에 쓰인
    /// 동그라미(`(①~③은 모두 옳다)`)를 구분자로 오인하면 한 문항이 통째로 망가지기 때문이다
    /// — 원본 50개를 훑어 실제로 1건 발견했다(2026-08-05).
    private static func splitOptions(_ line: String, startingAt alreadyCollected: Int) -> [String] {
        var out: [String] = []
        var buffer = ""
        var expected = alreadyCollected + 1
        var previous: Character?
        for character in line {
            let isBoundary = circledIndex(character) == expected
                && (previous == nil || previous == " " || previous == "\t")
            if isBoundary {
                let piece = buffer.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append(piece) }
                buffer = ""
                expected += 1
                previous = character
                continue
            }
            buffer.append(character)
            previous = character
        }
        let last = buffer.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `A. 옳은 것 고르기 (1~18)`·`A. 옳은 것 고르기 (18문항)` → `A. 옳은 것 고르기`.
    /// 괄호 안이 숫자로 시작하면 문항 수·범위 표시로 보고 떼어 낸다 — 형식 이름의 일부가 아니다.
    private static func sectionLabel(_ heading: String) -> String {
        guard let open = heading.lastIndex(of: "(") else { return heading }
        let tail = heading[heading.index(after: open)...].trimmingCharacters(in: .whitespaces)
        guard let first = tail.first, first.isNumber else { return heading }
        let trimmed = heading[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? heading : trimmed
    }

    // MARK: - 정답·해설부

    private static func parseAnswers(_ lines: [String]) -> [Int: Answer] {
        var answers: [Int: Answer] = [:]
        for line in lines {
            // 한 줄에 여러 문항의 해설이 나란히 붙어 있는 원본이 있다(`**45. ③** … **46. ②** …`).
            for entry in answerEntries(in: line) where answers[entry.0] == nil {
                answers[entry.0] = entry.1
            }
        }
        return answers
    }

    /// 한 줄에서 `**N. ②** 해설…` 을 모두 뽑는다. 다음 항목 직전까지가 그 항목의 해설이다.
    private static func answerEntries(in line: String) -> [(Int, Answer)] {
        var heads: [(number: Int, index: Int, start: String.Index, bodyStart: String.Index)] = []
        var cursor = line.startIndex
        while let markerStart = line.range(of: "**", range: cursor..<line.endIndex)?.lowerBound {
            var scan = line.index(markerStart, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
            let digitsStart = scan
            while scan < line.endIndex, line[scan].isNumber { scan = line.index(after: scan) }
            guard scan > digitsStart, let number = Int(line[digitsStart..<scan]),
                  scan < line.endIndex, line[scan] == "." else {
                cursor = line.index(markerStart, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            scan = line.index(after: scan)
            while scan < line.endIndex, line[scan] == " " { scan = line.index(after: scan) }
            guard scan < line.endIndex, let optionIndex = circledIndex(line[scan]) else {
                cursor = scan
                continue
            }
            scan = line.index(after: scan)
            guard let closing = line.range(of: "**", range: scan..<line.endIndex)?.upperBound else { break }
            heads.append((number, optionIndex, markerStart, closing))
            cursor = closing
        }

        return heads.enumerated().map { position, head in
            let bodyEnd = position + 1 < heads.count ? heads[position + 1].start : line.endIndex
            let raw = String(line[head.bodyStart..<bodyEnd])
            return (head.number, Answer(index: head.index,
                                        explanation: cleanExplanation(raw),
                                        page: pageNumber(in: raw)))
        }
    }

    private static func circledIndex(_ character: Character) -> Int? {
        guard let offset = circled.firstIndex(of: character) else { return nil }
        return circled.distance(from: circled.startIndex, to: offset) + 1
    }

    /// 해설에서 위키링크(`[[…|📖 p.009]]`)를 걷어내고 다듬는다 — 쪽은 `locator`가 따로 갖는다.
    private static func cleanExplanation(_ raw: String) -> String {
        var text = ""
        var depth = 0
        var iterator = raw.startIndex
        while iterator < raw.endIndex {
            if raw[iterator...].hasPrefix("[[") {
                depth += 1
                iterator = raw.index(iterator, offsetBy: 2)
                continue
            }
            if raw[iterator...].hasPrefix("]]"), depth > 0 {
                depth -= 1
                iterator = raw.index(iterator, offsetBy: 2)
                continue
            }
            if depth == 0 { text.append(raw[iterator]) }
            iterator = raw.index(after: iterator)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\ "))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func pageNumber(in raw: String) -> Int? {
        guard let marker = raw.range(of: "#page=") else { return nil }
        let digits = raw[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 학습 노트의 `### [문제 N] 제목` 자리에 쓸 짧은 제목 — 발문 첫 줄을 40자로 자른다.
    private static func title(from prompt: String, number: Int) -> String {
        let firstLine = prompt.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return "문제 \(number)" }
        guard firstLine.count > 40 else { return firstLine }
        return String(firstLine.prefix(40)) + "…"
    }
}
