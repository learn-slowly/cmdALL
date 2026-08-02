import Foundation

/// PDF 앞쪽의 **목차 페이지에 글자로 적힌 차례**를 읽어 장 목록을 뽑는다(순수 함수).
///
/// 배경(2026-08-02 실측, 설계 §목차 추출): 한국 PDF에는 내장 목차(`outlineRoot`)가 사실상
/// 없다 — 레고님 실제 교재(미디어교육사 562쪽)도 0개였다. 대신 4~5쪽에 이런 글자가 있다:
///
/// ```
/// 1.1.1. 미디어 개념과 특징 ∙ 008
/// 3.3.1. 미디어 리터러시 교육을 위한
/// 수업 전문성과 교육자 전문성 ∙ 500
/// ```
///
/// 그래서 이 파서가 진도 관리의 **주 경로**다. 파일 읽기는 호출부(`StudyOutlineExtractor`)가 한다.
enum StudyTOCTextParser {

    /// 목차 한 줄에서 뽑아낸 항목. `printedPage`는 **교재에 인쇄된 쪽번호**로, PDF 장 번호와
    /// 다를 수 있다(표지·목차 때문에 어긋난다 — 보정값은 `StudyPageOffset`가 따로 추정).
    struct Entry: Equatable {
        let title: String
        let printedPage: Int
    }

    /// 목차 페이지로 판정하는 데 필요한 최소 "제목 … 쪽번호" 줄 수.
    static let minimumTOCLines = 4
    /// 목차가 여러 장에 걸칠 때, 둘째 장부터 요구하는 최소 줄 수(이어지는 장은 몇 줄 안 될
    /// 수 있다 — 실제 교재도 마지막 목차 장이 서너 줄이다).
    static let minimumContinuationLines = 2
    /// 목차를 찾아볼 앞쪽 장 수.
    static let searchPageLimit = 20
    /// 제목과 쪽번호를 가르는 구분 기호(가운뎃점·점선·공백 등 실제 교재에서 쓰이는 것들).
    private static let separators = CharacterSet(charactersIn: " \t.·∙•‧・…-–—_→")

    /// 앞쪽 장들의 글자에서 목차를 찾아 항목 목록으로. 목차로 볼 만한 장이 없으면 빈 배열.
    ///
    /// 첫 목차 장은 기준(4줄)을 넘겨야 하지만, 그 뒤로 이어지는 장은 2줄이면 인정한다.
    /// 목차가 끝나면(항목이 거의 없는 장이 나오면) 더 뒤는 보지 않는다 — 본문 안의
    /// "표 목록" 같은 것을 목차로 잘못 주워 담지 않기 위해서다.
    /// - Parameter pageTexts: 1장부터 순서대로의 페이지 글자(호출부가 `searchPageLimit`까지만 넘긴다).
    static func entries(fromPageTexts pageTexts: [String]) -> [Entry] {
        var collected: [Entry] = []
        var started = false
        for text in pageTexts {
            let pageEntries = entries(fromPageText: text)
            if started {
                guard pageEntries.count >= minimumContinuationLines else { break }
            } else {
                guard pageEntries.count >= minimumTOCLines else { continue }
                started = true
            }
            collected.append(contentsOf: pageEntries)
        }
        return collected
    }

    /// 한 장의 글자에서 "제목 … 쪽번호" 줄만 뽑는다. 줄바꿈된 제목은 앞줄을 이어 붙인다.
    static func entries(fromPageText text: String) -> [Entry] {
        var out: [Entry] = []
        var pendingTitle = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { pendingTitle = ""; continue }

            guard let (title, page) = splitTrailingPageNumber(line) else {
                // 쪽번호가 없는 줄 — 줄바꿈된 제목의 앞부분일 수 있으니 들고 간다.
                // 상위 제목("1.1. …")도 여기로 오지만, 다음 줄이 쪽번호를 가지면 그 줄이
                // 자기 제목을 갖고 있으므로 아래 `mergedTitle`에서 자연히 밀려난다.
                pendingTitle = line
                continue
            }

            let merged = mergedTitle(pending: pendingTitle, tail: title)
            pendingTitle = ""
            guard !merged.isEmpty, !isFigureOrTableEntry(merged) else { continue }
            out.append(Entry(title: merged, printedPage: page))
        }
        return out
    }

    /// 줄 끝의 쪽번호를 떼어낸다. 번호가 없거나, 번호를 떼면 제목이 남지 않으면 nil.
    /// (예: "1.1.1. 미디어 개념과 특징 ∙ 008" → ("1.1.1. 미디어 개념과 특징", 8))
    static func splitTrailingPageNumber(_ line: String) -> (title: String, page: Int)? {
        var digits = ""
        var index = line.endIndex
        while index > line.startIndex {
            let previous = line.index(before: index)
            guard let scalar = line[previous].unicodeScalars.first,
                  CharacterSet.decimalDigits.contains(scalar) else { break }
            digits.insert(line[previous], at: digits.startIndex)
            index = previous
        }
        guard digits.count >= 1, digits.count <= 4, let page = Int(digits), page >= 1 else { return nil }

        var head = String(line[line.startIndex..<index])
        // 제목과 번호 사이에는 구분 기호가 반드시 하나는 있어야 한다 — 그래야 "제9장"
        // 같은 본문 줄이나 "2025" 같은 연도 줄을 목차로 오인하지 않는다.
        guard let last = head.unicodeScalars.last, separators.contains(last) else { return nil }
        head = head.trimmingCharacters(in: separators)
        guard !head.isEmpty else { return nil }
        // 제목이 숫자·기호만이면(예: 쪽 머리글) 버린다.
        guard head.rangeOfCharacter(from: CharacterSet.letters) != nil else { return nil }
        return (title: head, page: page)
    }

    /// 줄바꿈된 제목 잇기 — 앞줄이 쪽번호 없는 "제목의 앞부분"일 때만 붙인다.
    /// 앞줄이 상위 제목(끝이 마침표로 끝나는 절 제목 등)이어도 붙여서 나쁠 게 없지만,
    /// 명백히 다른 항목의 시작(번호로 시작하는 줄)이면 붙이지 않는다.
    private static func mergedTitle(pending: String, tail: String) -> String {
        let trimmedPending = pending.trimmingCharacters(in: .whitespaces)
        guard !trimmedPending.isEmpty else { return tail }
        guard !startsWithOutlineNumber(tail) else { return tail }
        guard startsWithOutlineNumber(trimmedPending) else { return tail }
        let merged = trimmedPending + " " + tail
        // 너무 길면 앞줄이 사실 다른 항목이었다는 뜻이다(실측: 스캔 논문의 표 목록에서
        // 여러 줄이 한 제목으로 뭉쳐 200자를 넘었다) — 그럴 땐 뒷줄만 쓴다.
        return merged.count <= maximumTitleLength ? merged : tail
    }

    /// 이어 붙인 제목의 최대 길이(글자 수).
    static let maximumTitleLength = 80

    /// 표·그림 목록 항목인지 — 교재 앞쪽엔 차례 말고 "표 목차"·"그림 목차"도 있는데,
    /// 그건 학습 단위가 아니라서 장으로 세면 진도가 엉망이 된다(실측: 스캔 논문에서 실제 발생).
    static func isFigureOrTableEntry(_ title: String) -> Bool {
        let head = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t<>[]〈〉《》(){}"))
        let markers = ["표", "그림", "도표", "부록표", "Table", "Figure", "표목차", "그림목차"]
        for marker in markers where head.hasPrefix(marker) {
            // "표 1-1", "<표 1>", "Table 2" 처럼 **바로 뒤에 번호**가 오는 것만 배제한다
            // ("표현의 자유" 같은 멀쩡한 제목을 잘라내지 않으려고).
            let rest = head.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if let first = rest.first, first.isNumber { return true }
        }
        return false
    }

    /// "1.", "1.1.", "1.1.1." 처럼 목차 번호로 시작하는 줄인지.
    static func startsWithOutlineNumber(_ line: String) -> Bool {
        var sawDigit = false
        for character in line {
            if character.isNumber { sawDigit = true; continue }
            if character == "." { return sawDigit }
            return false
        }
        return false
    }
}
