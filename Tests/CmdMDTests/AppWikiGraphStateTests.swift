import XCTest
@testable import CmdMD

/// 위키 관계도 화면(WikiGraph) AppState 배선 — 로드·통계·중복 로드 가드·시작 포커스 4경우.
@MainActor
final class AppWikiGraphStateTests: XCTestCase {
    var tempData: URL!
    var wikiDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
        app.settings.wikiFolder = wikiDir.path
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private func writePage(_ relativePath: String, body: String) {
        let url = wikiDir.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeActiveTab(fileURL: URL) {
        let document = MarkdownDocument(content: "")
        let tab = EditorTab(documentId: document.id, fileURL: fileURL)
        app.tabs = [tab]
        app.documents[document.id] = document
        app.activeTabId = tab.id
    }

    func testWithoutWikiFolderSetsError() async {
        app.settings.wikiFolder = nil
        await app.loadWikiGraph()
        XCTAssertNotNil(app.wikiGraphError)
        XCTAssertNil(app.wikiGraphSnapshot)
    }

    func testLoadBuildsStatsFromLinkedPages() async {
        writePage("a.md", body: "[[b]] [[없는페이지]]")
        writePage("b.md", body: "")
        await app.loadWikiGraph()
        let snapshot = try! XCTUnwrap(app.wikiGraphSnapshot)
        XCTAssertEqual(snapshot.graph.stats.nodeCount, 2)
        XCTAssertEqual(snapshot.graph.stats.edgeCount, 1)
        XCTAssertEqual(snapshot.graph.stats.unresolvedCount, 1)
        XCTAssertNil(app.wikiGraphError)
    }

    /// 로드 중 재호출 가드 — 이미 busy면 두 번째 호출은 조용히 무시(중복 로드 방지).
    func testDuplicateLoadCallWhileBusyIsIgnored() async {
        writePage("a.md", body: "")
        app.wikiGraphBusy = true   // 로드 중이라고 가정
        await app.loadWikiGraph()
        XCTAssertNil(app.wikiGraphSnapshot, "busy 중이면 새 로드를 시작하지 않아야 함")
        app.wikiGraphBusy = false
    }

    /// 포커스 경우 1 — 활성 탭이 위키 루트 안 + 노드에 존재 → 그 노드 중심 1-hop.
    func testFocusWhenActiveTabInsideWikiRootAndPresent() async {
        writePage("a.md", body: "[[b]]")
        writePage("b.md", body: "")
        makeActiveTab(fileURL: wikiDir.appendingPathComponent("a.md"))
        await app.loadWikiGraph()
        XCTAssertEqual(app.wikiGraphFocusedNodeID, "a.md")
        XCTAssertNotNil(app.wikiGraphFocusNotice)
        XCTAssertTrue(app.wikiGraphFocusNotice?.contains("주변") == true)
    }

    /// 포커스 경우 2 — 위키 루트 안이지만 절단으로 노드에서 빠짐 → 전체 보기 + 안내.
    func testFocusWhenActiveTabTruncatedOutOfLimit() async {
        var allPaths: [String] = []
        for i in 0..<501 {
            let name = String(format: "p%03d.md", i)
            allPaths.append(name)
            writePage(name, body: "")
        }
        let truncatedPage = allPaths.sorted()[500]   // 501번째(절단 밖)
        makeActiveTab(fileURL: wikiDir.appendingPathComponent(truncatedPage))
        await app.loadWikiGraph()
        XCTAssertNil(app.wikiGraphFocusedNodeID)
        XCTAssertTrue(app.wikiGraphFocusNotice?.contains("상한") == true)
    }

    /// 포커스 경우 3 — 활성 탭이 위키 루트 밖 → 전체 보기, 안내 없음.
    func testFocusWhenActiveTabOutsideWikiRoot() async {
        writePage("a.md", body: "")
        let outside = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(outside) }
        let outsideFile = outside.appendingPathComponent("바깥.md")
        try? "바깥 문서".write(to: outsideFile, atomically: true, encoding: .utf8)
        makeActiveTab(fileURL: outsideFile)
        await app.loadWikiGraph()
        XCTAssertNil(app.wikiGraphFocusedNodeID)
        XCTAssertNil(app.wikiGraphFocusNotice)
    }

    /// 포커스 경우 4 — 탭 없음 → 전체 보기, 안내 없음.
    func testFocusWhenNoActiveTab() async {
        writePage("a.md", body: "")
        app.tabs = []
        app.activeTabId = nil
        await app.loadWikiGraph()
        XCTAssertNil(app.wikiGraphFocusedNodeID)
        XCTAssertNil(app.wikiGraphFocusNotice)
    }

    func testOpenWikiGraphNodeOpensDocumentTab() async throws {
        writePage("a.md", body: "본문")
        app.openWikiGraphNode("a.md")
        var tries = 0
        while app.activeTab == nil && tries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertEqual(app.activeTab?.fileURL, wikiDir.appendingPathComponent("a.md"))
    }

    // MARK: - 왼쪽 리본 "위키" 버튼(openWikiHome)

    func testOpenWikiHomePrefersIndexMdWhenPresent() async throws {
        writePage("index.md", body: "홈")
        writePage("README.md", body: "안 씀 — index.md가 우선")
        app.openWikiHome()
        var tries = 0
        while app.activeTab == nil && tries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertEqual(app.activeTab?.fileURL, wikiDir.appendingPathComponent("index.md"))
    }

    func testOpenWikiHomeFallsBackToReadmeWhenNoIndex() async throws {
        writePage("README.md", body: "홈 대신")
        app.openWikiHome()
        var tries = 0
        while app.activeTab == nil && tries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertEqual(app.activeTab?.fileURL, wikiDir.appendingPathComponent("README.md"))
    }

    /// 후보 파일이 하나도 없으면 빈 화면 대신 최소한 위키 폴더라도 열어야 한다.
    func testOpenWikiHomeOpensFolderWhenNoCandidateExists() {
        writePage("아무거나.md", body: "")
        app.openWikiHome()
        XCTAssertEqual(app.currentFolder?.standardizedFileURL.path, wikiDir.standardizedFileURL.path)
        XCTAssertNotNil(app.toastMessage)
    }

    func testOpenWikiHomeTogglesToastWhenWikiFolderUnset() {
        app.settings.wikiFolder = nil
        app.openWikiHome()
        XCTAssertNotNil(app.toastMessage)
        XCTAssertNil(app.currentFolder)
    }
}
