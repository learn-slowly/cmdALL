import XCTest
@testable import CmdMD

final class AppOfficeTabTests: XCTestCase {

    // 각 테스트에 빈 임시 데이터 디렉터리를 주입해 세션 복원·디스크 의존성을 제거한다.
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testCurrentTabKindReflectsActiveOfficeTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                            title: "report", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .office)
        XCTAssertEqual(appState.currentTabFileURL, URL(fileURLWithPath: "/tmp/report.hwp"))
    }

    func testWindowTitleUsesFilenameForOfficeTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/평가서.hwp"),
                            title: "평가서", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id
        XCTAssertEqual(appState.windowTitle, "평가서")
    }

    // MARK: - Docufinder 격차 5번("원본 보기" 토글)

    @MainActor
    func testToggleOfficeOriginalViewTurnsOnAndOff() {
        let appState = AppState(dataDirectory: tempDir)
        let tabID = UUID()
        let docx = URL(fileURLWithPath: "/tmp/report.docx")

        appState.toggleOfficeOriginalView(tabID: tabID, fileURL: docx)
        XCTAssertTrue(appState.officeShowingOriginal.contains(tabID))

        appState.toggleOfficeOriginalView(tabID: tabID, fileURL: docx)
        XCTAssertFalse(appState.officeShowingOriginal.contains(tabID))
    }

    @MainActor
    func testToggleOfficeOriginalViewIgnoredForHWPFamily() {
        let appState = AppState(dataDirectory: tempDir)
        let tabID = UUID()
        let hwp = URL(fileURLWithPath: "/tmp/보고서.hwp")

        appState.toggleOfficeOriginalView(tabID: tabID, fileURL: hwp)

        XCTAssertFalse(appState.officeShowingOriginal.contains(tabID),
                        "HWP는 macOS QuickLook이 못 읽어 원본 보기가 켜지면 안 된다")
    }

    @MainActor
    func testBeginOfficeEditTurnsOffOriginalView() {
        let appState = AppState(dataDirectory: tempDir)
        let tabID = UUID()
        appState.officeShowingOriginal.insert(tabID)
        appState.officeStates[tabID] = .loaded(
            KordocResult(success: true, fileType: "docx", markdown: "본문", blocks: nil, outline: nil)
        )

        appState.beginOfficeEdit(tabID: tabID)

        XCTAssertFalse(appState.officeShowingOriginal.contains(tabID),
                        "편집은 마크다운에서만 가능하니 원본 보기 중이었으면 꺼져야 한다")
    }
}
