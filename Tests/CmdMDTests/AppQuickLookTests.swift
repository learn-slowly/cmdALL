import XCTest
@testable import CmdMD

/// "글로 열기" 전환(스펙 §4) — 미리보기 탭을 편집기로.
@MainActor
final class AppQuickLookTests: XCTestCase {

    private var tempDir: URL!
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = TempDataDirectory.make()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("글로열기-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TempDataDirectory.cleanup(tempDir)
        try? FileManager.default.removeItem(at: workDir)
        tempDir = nil
        workDir = nil
        try super.tearDownWithError()
    }

    func test글로열기가탭을편집기로바꾼다() async throws {
        let file = workDir.appendingPathComponent("설정.mdx")
        try "# 제목\n본문입니다".write(to: file, atomically: true, encoding: .utf8)

        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: file, title: "설정", kind: .quickLook)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        await appState.reopenAsText(tabID: tab.id)

        XCTAssertEqual(appState.tabs.first?.kind, .markdown)
        let docID = try XCTUnwrap(appState.tabs.first?.documentId)
        XCTAssertNotNil(appState.documents[docID], "문서가 실려야 한다")
        XCTAssertEqual(appState.documents[docID]?.fullText, "# 제목\n본문입니다")
        XCTAssertNotNil(appState.originalContents[docID], "저장 기준선이 잡혀야 한다")
    }

    func test미리보기탭이아니면아무일도하지않는다() async throws {
        let file = workDir.appendingPathComponent("사진.png")
        try "가짜".write(to: file, atomically: true, encoding: .utf8)

        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: file, title: "사진", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        await appState.reopenAsText(tabID: tab.id)

        XCTAssertEqual(appState.tabs.first?.kind, .image, "이미지 탭은 그대로여야 한다")
    }

    func test없는탭이면조용히넘어간다() async {
        let appState = AppState(dataDirectory: tempDir)
        await appState.reopenAsText(tabID: UUID())
        XCTAssertTrue(appState.tabs.isEmpty)
    }
}
