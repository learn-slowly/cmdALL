import XCTest
@testable import CmdMD

@MainActor
final class AppOpenFolderAtTests: XCTestCase {
    private var tempDir: URL!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
        appState = AppState(dataDirectory: tempDir)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        appState = nil
        super.tearDown()
    }

    func testOpenFolderAt_switchesWorkspaceState() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        appState.openFolder(at: folder)

        XCTAssertEqual(appState.currentFolder, folder)
        XCTAssertEqual(appState.selectedFolder, folder)
        XCTAssertEqual(appState.selectedSidebarTab, .files)
        XCTAssertTrue(appState.sidebarVisible)
    }

    /// §방법2: 폴더를 열면 "등록" 버튼 없이 자동으로 내용 검색 인덱스에 들어가야 한다.
    func testOpenFolderAt_autoRegistersForContentIndexing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-autoindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        appState.openFolder(at: folder)

        let canonical = SearchIndexer.canonicalURL(folder).path
        for _ in 0..<200 where !appState.settings.indexedFolders.contains(canonical) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(appState.settings.indexedFolders.contains(canonical),
                       "폴더를 열면 사람이 등록 버튼을 누르지 않아도 색인 목록에 자동으로 들어가야 한다")
    }

    /// 사이드바 기본 위치(홈·데스크탑·다운로드·문서)처럼 그냥 훑어보기용 호출은
    /// autoIndex: false로 넘겨 폴더 전체가 색인 대상으로 둔갑하지 않아야 한다.
    func testOpenFolderAt_autoIndexFalseSkipsRegistration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-noautoindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        appState.openFolder(at: folder, autoIndex: false)

        // 등록 자체가 안 걸리니 잠깐 기다려도 목록엔 안 들어가야 한다(음성 확인).
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let canonical = SearchIndexer.canonicalURL(folder).path
        XCTAssertFalse(appState.settings.indexedFolders.contains(canonical),
                        "훑어보기용 호출(autoIndex: false)은 내용 색인에 등록되면 안 된다")
    }
}
