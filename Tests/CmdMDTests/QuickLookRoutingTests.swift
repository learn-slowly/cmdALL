import XCTest
@testable import CmdMD

/// 확장자 → "글로 열기 / 애플 미리보기" 판정(스펙 §3).
final class QuickLookRoutingTests: XCTestCase {

    func test맥이글자라답하는확장자는글로연다() {
        for ext in ["csv", "json", "swift", "log", "yml", "xml", "html", "py", "sh", "md", "txt"] {
            XCTAssertTrue(QuickLookRouting.opensAsText(extension: ext),
                          "\(ext)는 글로 열어야 한다")
        }
    }

    func test글자가아닌확장자는미리보기로간다() {
        for ext in ["pptx", "ppt", "key", "numbers", "pages", "zip", "psd", "ai", "epub", "ttf", "dmg", "app"] {
            XCTAssertFalse(QuickLookRouting.opensAsText(extension: ext),
                           "\(ext)는 미리보기로 가야 한다")
        }
    }

    func testRtf는글자라답해도미리보기로간다() {
        // 맥은 rtf를 public.rtf(텍스트 계열)로 답하지만 편집기로 열면 서식 부호가 보인다.
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "rtf"))
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "rtfd"))
    }

    func test맥이모르는흔한글자확장자는빠른경로가구제한다() {
        // .conf/.ini/.toml은 맥이 dyn.…으로 답해 '글자 아님'이 된다(실측).
        // 빠른 경로 목록이 이를 구제한다.
        for ext in ["conf", "ini", "toml"] {
            XCTAssertTrue(QuickLookRouting.opensAsText(extension: ext))
        }
    }

    func test확장자없으면미리보기로간다() {
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: ""))
    }

    func test대소문자를무시한다() {
        XCTAssertTrue(QuickLookRouting.opensAsText(extension: "JSON"))
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "PPTX"))
    }

    func test아는여섯종류는quickLook으로새지않는다() {
        // 판정 순서 안전장치 — 기존 갈래가 새 갈래로 새면 회귀다.
        let known = ["md", "markdown", "txt", "png", "jpg", "heic", "gif", "pdf",
                     "hwp", "hwpx", "docx", "xlsx", "mp3", "wav", "mp4", "mov"]
        for ext in known {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertNotEqual(DocumentKind(from: url), .quickLook,
                              "\(ext)는 기존 갈래를 유지해야 한다")
        }
    }

    func test모르는형식은quickLook갈래가된다() {
        for ext in ["pptx", "zip", "psd", "key", "epub"] {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .quickLook)
        }
    }

    func test글자파일은markdown갈래를유지한다() {
        for ext in ["json", "swift", "csv", "yml"] {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .markdown)
        }
    }

    func testQuickLook정렬순위는맨끝이다() {
        XCTAssertGreaterThan(DocumentKind.quickLook.sortRank, DocumentKind.media.sortRank)
    }
}
