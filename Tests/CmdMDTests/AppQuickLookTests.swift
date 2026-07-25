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

    // MARK: - 스페이스바 빠른 보기(스펙 §5)

    func test선택한파일들이화면순서대로후보가된다() {
        let appState = AppState(dataDirectory: tempDir)
        let a = URL(fileURLWithPath: "/tmp/가.png")
        let b = URL(fileURLWithPath: "/tmp/나.pdf")
        let c = URL(fileURLWithPath: "/tmp/다.zip")
        appState.libraryOrderedURLs = [a, b, c]
        appState.fileSelection = [c, a]

        XCTAssertEqual(appState.quickLookCandidates(), [a, c],
                       "화면에 보이는 순서를 따라야 한다")
    }

    func test선택이없으면후보가없다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.libraryOrderedURLs = [URL(fileURLWithPath: "/tmp/가.png")]
        appState.fileSelection = []

        XCTAssertTrue(appState.quickLookCandidates().isEmpty)
    }

    func test열고닫기가상태를바꾼다() {
        let appState = AppState(dataDirectory: tempDir)
        let urls = [URL(fileURLWithPath: "/tmp/가.png"), URL(fileURLWithPath: "/tmp/나.zip")]

        appState.openQuickLook(urls: urls)
        XCTAssertTrue(appState.isQuickLookPresented)
        XCTAssertEqual(appState.quickLookURLs, urls)
        XCTAssertEqual(appState.quickLookIndex, 0)

        appState.closeQuickLook()
        XCTAssertFalse(appState.isQuickLookPresented)
        XCTAssertTrue(appState.quickLookURLs.isEmpty)
    }

    func test좌우이동은양끝에서멈춘다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.openQuickLook(urls: [URL(fileURLWithPath: "/tmp/가.png"),
                                      URL(fileURLWithPath: "/tmp/나.zip")])

        appState.stepQuickLook(by: -1)
        XCTAssertEqual(appState.quickLookIndex, 0, "첫 항목에서 왼쪽은 제자리")

        appState.stepQuickLook(by: 1)
        XCTAssertEqual(appState.quickLookIndex, 1)

        appState.stepQuickLook(by: 1)
        XCTAssertEqual(appState.quickLookIndex, 1, "마지막에서 오른쪽은 제자리")
    }

    func test글자입력중이면스페이스를가로채지않는다() {
        // 이 저장소에서 세 번 반복된 키 강탈 결함 방지(스펙 §5).
        // NSTextField.currentEditor()는 창에 붙어 first responder가 돼야만 값이 생기므로
        // 헤드리스 테스트에선 항상 nil — 대신 기존 F1b 테스트가 쓰는 헤드리스 NSTextView로
        // 직접 검증한다(AppPasteboardActionsTests·AppNavigationHistoryTests와 같은 패턴).
        XCTAssertTrue(AppState.responderYieldsFileKeys(NSTextView()),
                      "글자 입력칸은 파일 키를 양보받아야 한다")
    }

    func test빈선택에서는빠른보기가열리지않는다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.fileSelection = []
        appState.openQuickLook(urls: appState.quickLookCandidates())
        XCTAssertFalse(appState.isQuickLookPresented, "후보가 없으면 열리지 않는다")
    }
}
