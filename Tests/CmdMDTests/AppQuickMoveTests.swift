import XCTest
@testable import CmdMD

/// 빠른 이동 목록 등록·해제(스펙 §4.1 — 즐겨찾기와 별개, 사용자가 직접 등록).
final class AppQuickMoveTests: XCTestCase {
    var appState: AppState!
    var tempData: URL!
    var folder: URL!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        appState = AppState(dataDirectory: tempData)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func test등록하면목록에추가된다() {
        appState.addToQuickMoveFolders(folder)
        XCTAssertEqual(appState.quickMoveFolders.map(\.url), [folder])
        XCTAssertTrue(appState.isQuickMoveFolder(folder))
    }

    func test같은폴더재등록은무시된다() {
        appState.addToQuickMoveFolders(folder)
        appState.addToQuickMoveFolders(folder)
        XCTAssertEqual(appState.quickMoveFolders.count, 1)
    }

    func test해제하면목록에서빠진다() {
        appState.addToQuickMoveFolders(folder)
        let entry = appState.quickMoveFolders[0]
        appState.removeFromQuickMoveFolders(entry)
        XCTAssertTrue(appState.quickMoveFolders.isEmpty)
        XCTAssertFalse(appState.isQuickMoveFolder(folder))
    }

    func test저장후다시읽으면유지된다() {
        appState.addToQuickMoveFolders(folder)
        appState.saveUserData()

        let reloaded = AppState(dataDirectory: tempData)
        XCTAssertEqual(reloaded.quickMoveFolders.map(\.url), [folder])
    }

    func test존재하지않는경로는로드시걸러진다() {
        appState.addToQuickMoveFolders(folder)
        appState.saveUserData()
        try? FileManager.default.removeItem(at: folder)

        let reloaded = AppState(dataDirectory: tempData)
        XCTAssertTrue(reloaded.quickMoveFolders.isEmpty)
    }
}
