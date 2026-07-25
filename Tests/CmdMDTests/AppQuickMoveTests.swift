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

    func test빠른이동단축키는옵션커맨드M이다() {
        let binding = AppShortcut.quickMove.defaultBinding
        XCTAssertEqual(binding.key, "m")
        XCTAssertTrue(binding.command)
        XCTAssertTrue(binding.option)
        XCTAssertFalse(binding.shift)
    }

    func test빠른이동단축키는다른커맨드와겹치지않는다() {
        let quickMove = AppShortcut.quickMove.defaultBinding
        for shortcut in AppShortcut.allCases where shortcut != .quickMove {
            let other = shortcut.defaultBinding
            let same = other.key == quickMove.key && other.command == quickMove.command
                && other.shift == quickMove.shift && other.option == quickMove.option
                && other.control == quickMove.control
            XCTAssertFalse(same, "\(shortcut)와 단축키가 겹친다")
        }
    }

    func test빠른이동요청하면대상과시트상태가세팅된다() {
        appState.fileSelection = [folder]
        appState.promptQuickMove()
        XCTAssertTrue(appState.showQuickMove)
        XCTAssertEqual(appState.quickMoveTargets, [folder])
    }

    func test선택이비어있으면빠른이동요청은무시된다() {
        appState.fileSelection = []
        appState.promptQuickMove()
        XCTAssertFalse(appState.showQuickMove)
    }

    func test목적지선택하면기존배치이동을탄다() async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmove-dest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)

        appState.promptQuickMove(urls: [file])
        _ = await appState.performBatchMove(urls: appState.quickMoveTargets, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
