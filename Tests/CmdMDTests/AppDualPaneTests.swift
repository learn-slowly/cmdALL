import XCTest
@testable import CmdMD

/// 두 폴더 나란히 보기(듀얼 페인) — 켜고 끄기·포커스 전환·사이드바 라우팅(설계 §3.1, 계획 Task 2).
@MainActor
final class AppDualPaneTests: XCTestCase {
    var appState: AppState!
    var root: URL!

    override func setUpWithError() throws {
        let tempData = TempDataDirectory.make()
        appState = AppState(dataDirectory: tempData)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualpane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        appState.currentFolder = root
    }

    func test처음엔꺼져있고칸이없다() {
        XCTAssertFalse(appState.dualPaneEnabled)
        XCTAssertTrue(appState.panes.isEmpty)
    }

    func test켜면칸이2개생기고둘다현재폴더로초기화된다() {
        appState.toggleDualPane()
        XCTAssertTrue(appState.dualPaneEnabled)
        XCTAssertEqual(appState.panes.count, 2)
        XCTAssertEqual(appState.panes[0].rootFolder, root)
        XCTAssertEqual(appState.panes[1].rootFolder, root)
        XCTAssertEqual(appState.focusedPaneIndex, 0)
    }

    func test끄면화면분기만꺼지고칸상태는남는다() {
        appState.toggleDualPane()
        appState.openFolderInFocusedPane(root.appendingPathComponent("sub"))
        appState.toggleDualPane()
        XCTAssertFalse(appState.dualPaneEnabled)
        XCTAssertEqual(appState.panes[0].selectedFolder, root.appendingPathComponent("sub"),
                       "꺼도 칸 상태(세션 내 기억)는 지워지지 않아야 한다")
    }

    func test다시켜면마지막폴더가그대로다() {
        appState.toggleDualPane()
        let sub = root.appendingPathComponent("sub")
        appState.openFolderInFocusedPane(sub)
        appState.toggleDualPane()
        appState.toggleDualPane()
        XCTAssertEqual(appState.panes[0].selectedFolder, sub)
    }

    func testFocusPane이유효한범위만받아들인다() {
        appState.toggleDualPane()
        appState.focusPane(1)
        XCTAssertEqual(appState.focusedPaneIndex, 1)
        appState.focusPane(99)
        XCTAssertEqual(appState.focusedPaneIndex, 1, "범위 밖 인덱스는 무시해야 한다")
    }

    func testOpenFolderInFocusedPane은포커스칸만바꾼다() {
        appState.toggleDualPane()
        appState.focusPane(1)
        let sub = root.appendingPathComponent("sub")
        appState.openFolderInFocusedPane(sub)
        XCTAssertEqual(appState.panes[1].selectedFolder, sub)
        XCTAssertEqual(appState.panes[0].selectedFolder, root, "포커스 없는 칸은 안 바뀌어야 한다")
    }

    func test두칸이꺼져있는채로openFolderInFocusedPane을불러도무해하다() {
        // panes가 비어 있을 때(toggleDualPane 호출 전) 방어 확인.
        appState.openFolderInFocusedPane(root.appendingPathComponent("sub"))
        XCTAssertTrue(appState.panes.isEmpty)
    }
}
