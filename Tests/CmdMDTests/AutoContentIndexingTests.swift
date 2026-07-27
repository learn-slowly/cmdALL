import XCTest
@testable import CmdMD

/// §방법2(검색 통합): 폴더를 열거나 볼트를 연결하면 "등록" 버튼 없이 자동으로 내용
/// 검색 색인에 들어가고, Omnisearch의 내용 검색(searchContent)이 그 색인에서 결과를
/// 가져오는지(pdf·오피스도 커버하는 색인 경로) 확인한다.
@MainActor
final class AutoContentIndexingTests: XCTestCase {
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


    func testAddVaultAutoRegistersRootForContentIndexing() throws {
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-autoindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        appState.addVault(Vault(name: "테스트볼트", rootPath: vaultRoot))

        let canonical = SearchIndexer.canonicalURL(vaultRoot).path
        for _ in 0..<200 where !appState.settings.indexedFolders.contains(canonical) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(appState.settings.indexedFolders.contains(canonical),
                       "볼트를 연결하면 손으로 등록하지 않아도 색인 목록에 자동으로 들어가야 한다")
    }

    func testSearchContentFindsBodyTextViaIndexAfterAutoRegistration() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-searchcontent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let needle = "홍시사과나무비밀코드"
        try "여기 \(needle) 들어있다".write(
            to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        appState.openFolder(at: folder)
        // openFolder(at:)의 registerIndexFolder 호출은 MainActor Task로 한 틱 늦게 실행된다.
        for _ in 0..<200 where appState.settings.indexedFolders.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        while appState.indexInProgress {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let hits = await appState.searchContent(query: needle)
        XCTAssertTrue(hits.contains { $0.path.hasSuffix("note.txt") },
                      "자동으로 훑어둔 색인에서 본문 단어로 파일을 찾아야 한다")
    }

    func testSearchContentReturnsEmptyForBlankQuery() async {
        let hits = await appState.searchContent(query: "")
        XCTAssertTrue(hits.isEmpty)
    }
}
