import Foundation

/// .eml(RFC 822/2822) 파일 → 검색 가능한 텍스트(Docufinder 격차 7번 — 이메일 검색).
/// 완전한 MIME 파서가 아니라 실사용에 필요한 만큼만 다룬다: 헤더 블록(제목·보낸사람·받는사람)
/// 파싱 + RFC 2047 인코디드 워드(한국어 제목이 거의 항상 이 형식) 디코딩 + 첫 text/plain
/// 파트(또는 단순 본문) 추출. 복잡한 첨부·중첩 multipart는 최선 노력 — 디코딩 실패해도
/// 원문 그대로 남긴다(크래시·예외 없음, 순수 함수).
enum EmailExtractor {
    struct Fields: Equatable {
        var subject: String = ""
        var from: String = ""
        var to: String = ""
        var body: String = ""
    }

    /// 원문(.eml 파일 그대로 읽은 문자열) → 검색 인덱스에 넣을 텍스트.
    static func searchableText(rawEML raw: String) -> String {
        let fields = parse(raw)
        var parts: [String] = []
        if !fields.subject.isEmpty { parts.append("제목: \(fields.subject)") }
        if !fields.from.isEmpty { parts.append("보낸사람: \(fields.from)") }
        if !fields.to.isEmpty { parts.append("받는사람: \(fields.to)") }
        if !fields.body.isEmpty { parts.append(fields.body) }
        return parts.joined(separator: "\n")
    }

    static func parse(_ raw: String) -> Fields {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headerBlock, bodyBlock) = splitHeaderAndBody(normalized)
        let headers = headerMap(from: headerBlock)

        var fields = Fields()
        fields.subject = decodeEncodedWords(headers["subject"] ?? "")
        fields.from = decodeEncodedWords(headers["from"] ?? "")
        fields.to = decodeEncodedWords(headers["to"] ?? "")
        fields.body = extractBody(bodyBlock, headers: headers)
        return fields
    }

    // MARK: - 헤더/본문 분리

    /// 첫 빈 줄까지가 헤더(RFC 2822 §2.1). 빈 줄이 없으면 전부 헤더 취급(본문 없음).
    static func splitHeaderAndBody(_ normalized: String) -> (header: String, body: String) {
        guard let range = normalized.range(of: "\n\n") else { return (normalized, "") }
        return (String(normalized[normalized.startIndex..<range.lowerBound]),
                String(normalized[range.upperBound...]))
    }

    /// 접힌 헤더(다음 줄이 공백/탭으로 시작 = 이전 헤더 연속, RFC 2822 §2.2.3)를 합쳐
    /// 소문자 헤더명 → 값 딕셔너리로. 같은 이름이 반복되면 마지막 값이 이긴다(단순화).
    static func headerMap(from headerBlock: String) -> [String: String] {
        var lines: [String] = []
        for raw in headerBlock.components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + raw.trimmingCharacters(in: .whitespaces)
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        var map: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            map[name] = value
        }
        return map
    }

    // MARK: - RFC 2047 인코디드 워드(`=?charset?B|Q?text?=`)

    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?"), let regex = Self.encodedWordRegex else { return value }
        var result = value
        let nsValue = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsValue.length))
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let charset = nsValue.substring(with: match.range(at: 1))
            let encoding = nsValue.substring(with: match.range(at: 2)).lowercased()
            let text = nsValue.substring(with: match.range(at: 3))
            let decoded = decodeWord(text: text, encoding: encoding, charset: charset)
                ?? nsValue.substring(with: match.range)
            result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
        }
        // 인코디드 워드 사이의 접합 공백(RFC 2047 §6.2, 폴딩 화이트스페이스)을 정리.
        return result.replacingOccurrences(of: "?= =?", with: "?==?")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static let encodedWordRegex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)

    private static func decodeWord(text: String, encoding: String, charset: String) -> String? {
        let enc = stringEncoding(forCharset: charset)
        switch encoding {
        case "b":
            guard let data = Data(base64Encoded: text) else { return nil }
            return String(data: data, encoding: enc)
        case "q":
            return decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "), encoding: enc)
        default:
            return nil
        }
    }

    private static func stringEncoding(forCharset charset: String) -> String.Encoding {
        let key = charset.lowercased()
        if key.contains("utf-8") || key.contains("utf8") { return .utf8 }
        if key.contains("euc-kr") || key.contains("euckr") || key.contains("ks_c_5601") {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        }
        if key.contains("iso-2022-kr") {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.ISO_2022_KR.rawValue)))
        }
        return .utf8
    }

    /// `=XX` 16진 이스케이프 → 바이트, 나머지는 그대로 → 지정 인코딩으로 문자열화.
    /// 소프트 줄바꿈(줄 끝 `=`)은 제거(RFC 2045 §6.7 — 다음 줄과 이어붙임).
    private static func decodeQuotedPrintable(_ text: String, encoding: String.Encoding) -> String? {
        let joined = text.replacingOccurrences(of: "=\n", with: "")
        var data = Data()
        let chars = Array(joined)
        var i = 0
        while i < chars.count {
            if chars[i] == "=", i + 2 < chars.count,
               let byte = UInt8(String(chars[i + 1]) + String(chars[i + 2]), radix: 16) {
                data.append(byte)
                i += 3
            } else {
                data.append(contentsOf: Array(String(chars[i]).utf8))
                i += 1
            }
        }
        return String(data: data, encoding: encoding)
    }

    // MARK: - 본문(단순 또는 multipart 첫 text/plain 파트)

    static func extractBody(_ bodyBlock: String, headers: [String: String]) -> String {
        let contentType = headers["content-type"] ?? ""
        if contentType.lowercased().contains("multipart"), let boundary = boundary(from: contentType) {
            return firstPlainTextPart(in: bodyBlock, boundary: boundary) ?? bodyBlock
        }
        return decodedTransferBody(bodyBlock, headers: headers)
    }

    private static func boundary(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var value = String(contentType[range.upperBound...])
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
    }

    private static func firstPlainTextPart(in bodyBlock: String, boundary: String) -> String? {
        let marker = "--\(boundary)"
        let parts = bodyBlock.components(separatedBy: marker).dropFirst() // 첫 조각은 boundary 이전 프리앰블
        for rawPart in parts {
            let trimmed = rawPart.trimmingCharacters(in: .newlines)
            if trimmed.hasPrefix("--") { continue } // 종료 boundary(`--boundary--`)
            let (partHeaderBlock, partBody) = splitHeaderAndBody(trimmed)
            let partHeaders = headerMap(from: partHeaderBlock)
            let partType = (partHeaders["content-type"] ?? "text/plain").lowercased()
            if partType.contains("text/plain") {
                return decodedTransferBody(partBody, headers: partHeaders)
            }
        }
        return nil
    }

    private static func decodedTransferBody(_ body: String, headers: [String: String]) -> String {
        let transferEncoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let enc = stringEncoding(forCharset: charset(from: headers["content-type"] ?? ""))
        switch transferEncoding {
        case "base64":
            let compact = body.filter { !$0.isNewline && !$0.isWhitespace }
            if let data = Data(base64Encoded: compact), let decoded = String(data: data, encoding: enc) {
                return decoded
            }
            return body
        case "quoted-printable":
            return decodeQuotedPrintable(body, encoding: enc) ?? body
        default:
            return body
        }
    }

    private static func charset(from contentType: String) -> String {
        guard let range = contentType.range(of: "charset=") else { return "utf-8" }
        var value = String(contentType[range.upperBound...])
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
    }
}
