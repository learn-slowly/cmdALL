import XCTest
@testable import CmdMD

final class EmailExtractorTests: XCTestCase {

    func testDecodesUTF8Base64EncodedSubject() {
        let subject = "회의 안건 공유"
        let encoded = Data(subject.utf8).base64EncodedString()
        let raw = "From: hong@example.com\nSubject: =?UTF-8?B?\(encoded)?=\n\n본문"

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.subject, subject)
    }

    func testDecodesQuotedPrintableSubject() {
        // "가"(U+AC00)의 UTF-8 바이트는 EA B0 80 — RFC 2047 Q-인코딩 형식으로 직접 구성.
        let raw = "Subject: =?UTF-8?Q?=EA=B0=80?=\n\n본문"

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.subject, "가")
    }

    func testPlainBodyPassthroughWhenNoTransferEncoding() {
        let raw = "From: a@x.com\nTo: b@x.com\nSubject: 테스트\n\n본문 내용입니다."

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.from, "a@x.com")
        XCTAssertEqual(fields.to, "b@x.com")
        XCTAssertEqual(fields.subject, "테스트")
        XCTAssertTrue(fields.body.contains("본문 내용입니다."))
    }

    func testDecodesBase64Body() {
        let bodyText = "안녕하세요\n첨부파일을 확인해주세요."
        let encodedBody = Data(bodyText.utf8).base64EncodedString()
        let raw = "From: a@x.com\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n\(encodedBody)"

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.body, bodyText)
    }

    func testDecodesQuotedPrintableBody() {
        let raw = "From: a@x.com\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable\n\n=EA=B0=80"

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.body, "가")
    }

    func testExtractsFirstPlainTextPartFromMultipart() {
        let plain = "이것은 본문입니다."
        let raw = [
            "From: a@x.com",
            "Subject: 여러 파트",
            "Content-Type: multipart/alternative; boundary=\"BOUND\"",
            "",
            "--BOUND",
            "Content-Type: text/plain; charset=UTF-8",
            "",
            plain,
            "--BOUND",
            "Content-Type: text/html; charset=UTF-8",
            "",
            "<p>\(plain)</p>",
            "--BOUND--",
        ].joined(separator: "\n")

        let fields = EmailExtractor.parse(raw)

        XCTAssertTrue(fields.body.contains(plain))
        XCTAssertFalse(fields.body.contains("<p>"), "html 파트가 아니라 text/plain 파트를 골라야 한다")
    }

    func testFoldedHeaderLinesAreJoined() {
        let raw = "Subject: 첫 줄\n 이어지는 줄\nFrom: a@x.com\n\n본문"

        let fields = EmailExtractor.parse(raw)

        XCTAssertEqual(fields.subject, "첫 줄 이어지는 줄")
        XCTAssertEqual(fields.from, "a@x.com", "접힌 헤더 다음 줄이 다음 헤더까지 삼키면 안 된다")
    }

    func testSearchableTextIncludesLabeledFields() {
        let raw = "From: a@x.com\nTo: b@x.com\nSubject: 회의록\n\n본문내용"

        let text = EmailExtractor.searchableText(rawEML: raw)

        XCTAssertTrue(text.contains("제목: 회의록"))
        XCTAssertTrue(text.contains("보낸사람: a@x.com"))
        XCTAssertTrue(text.contains("받는사람: b@x.com"))
        XCTAssertTrue(text.contains("본문내용"))
    }

    func testSearchableTextOmitsEmptyFields() {
        let raw = "Subject: 제목만\n\n본문"

        let text = EmailExtractor.searchableText(rawEML: raw)

        XCTAssertFalse(text.contains("보낸사람:"))
        XCTAssertFalse(text.contains("받는사람:"))
    }

    func testContentExtractorLocalBodyHandlesEmlFile() throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = dir.appendingPathComponent("mail.eml")
        try "From: a@x.com\nSubject: 테스트 메일\n\n본문".write(to: url, atomically: true, encoding: .utf8)

        let body = ContentExtractor.localBody(for: url)

        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("테스트 메일"))
    }

    func testIsSummarizableAcceptsEml() {
        XCTAssertTrue(AppState.isSummarizable(url: URL(fileURLWithPath: "/tmp/a.eml")))
    }
}
