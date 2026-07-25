import XCTest
@testable import CmdMD

/// 목록 노출 규칙 — 모든 파일 표시(스펙 §3.5) + 숨김 파일 옵션.
final class FileListingVisibilityTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("목록테스트-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["보고서.md", "발표.pptx", "묶음.zip", "설정.json", ".숨김파일", ".gitignore"] {
            try "내용".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func names(_ items: [FileTreeItem]) -> Set<String> {
        Set(items.map { $0.url.lastPathComponent })
    }

    func test모르는형식도목록에보인다() {
        let got = names(LibraryListing.entries(of: dir))
        XCTAssertTrue(got.contains("발표.pptx"), "pptx가 목록에 보여야 한다")
        XCTAssertTrue(got.contains("묶음.zip"), "zip이 목록에 보여야 한다")
        XCTAssertTrue(got.contains("설정.json"))
        XCTAssertTrue(got.contains("보고서.md"), "기존 형식은 그대로 보여야 한다")
    }

    func test숨김파일은기본으로안보인다() {
        let got = names(LibraryListing.entries(of: dir))
        XCTAssertFalse(got.contains(".숨김파일"))
        XCTAssertFalse(got.contains(".gitignore"))
    }

    func test숨김파일옵션을켜면보인다() {
        let got = names(LibraryListing.entries(of: dir, showHidden: true))
        XCTAssertTrue(got.contains(".숨김파일"))
        XCTAssertTrue(got.contains(".gitignore"))
        XCTAssertTrue(got.contains("보고서.md"), "켜도 일반 파일은 그대로 보인다")
    }

    func test트리도같은규칙을따른다() {
        let 기본 = names(AppState.buildFileTree(at: dir, expanded: []))
        XCTAssertTrue(기본.contains("발표.pptx"))
        XCTAssertFalse(기본.contains(".gitignore"))

        let 숨김켬 = names(AppState.buildFileTree(at: dir, expanded: [], showHidden: true))
        XCTAssertTrue(숨김켬.contains(".gitignore"))
    }

    func test짝꿍노트숨김은그대로동작한다() throws {
        // 목록을 열어도 미디어의 짝꿍 노트는 계속 숨어야 한다(회귀 방지).
        try "소리".write(to: dir.appendingPathComponent("노래.mp3"), atomically: true, encoding: .utf8)
        try "메모".write(to: dir.appendingPathComponent("노래.mp3.md"), atomically: true, encoding: .utf8)

        let got = names(LibraryListing.entries(of: dir))
        XCTAssertTrue(got.contains("노래.mp3"))
        XCTAssertFalse(got.contains("노래.mp3.md"), "짝꿍 노트는 계속 숨어야 한다")
    }

    func test설정기본값은숨김끔이다() {
        XCTAssertFalse(AppSettings().showHiddenFiles)
    }

    func test옛설정파일에키가없어도끔으로읽는다() throws {
        // AppTheme의 실제 rawValue는 대문자 "System"이다(계획 초안의 소문자 값은
        // 오타 — 이 테스트의 취지는 theme 값 자체가 아니라 showHiddenFiles 키
        // 부재 시 기본값 폴백이므로 유효한 rawValue로 바로잡는다).
        let json = Data(#"{"theme":"System"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.showHiddenFiles)
    }
}
