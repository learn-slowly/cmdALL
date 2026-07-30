import XCTest
@testable import CmdMD

/// `WikiGraphBuilder` — 링크 해석·절단 분류·엣지 축약/상한(순수 함수, 디스크 접근 없음).
final class WikiGraphBuilderTests: XCTestCase {
    func testEmptyPagesProducesEmptyGraph() {
        let graph = WikiGraphBuilder.build(allPages: [], bodies: [:])
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertEqual(graph.stats.nodeCount, 0)
    }

    func testResolvesMarkdownLinkInSameFolder() {
        let bodies = ["a.md": "[b](b.md)", "b.md": ""]
        let graph = WikiGraphBuilder.build(allPages: ["a.md", "b.md"], bodies: bodies)
        XCTAssertEqual(graph.edges.map(\.from), ["a.md"])
        XCTAssertEqual(graph.edges.map(\.to), ["b.md"])
    }

    func testResolvesMarkdownLinkWithParentAndSubfolder() {
        // folder/a.md -> ../root.md, folder/a.md -> sub/c.md
        let bodies: [String: String] = [
            "folder/a.md": "[상위](../root.md) [하위](sub/c.md)",
            "root.md": "",
            "folder/sub/c.md": "",
        ]
        let graph = WikiGraphBuilder.build(allPages: ["folder/a.md", "folder/sub/c.md", "root.md"], bodies: bodies)
        let targets = Set(graph.edges.filter { $0.from == "folder/a.md" }.map(\.to))
        XCTAssertEqual(targets, ["root.md", "folder/sub/c.md"])
    }

    func testMarkdownLinkExtensionOmittedResolves() {
        let bodies = ["a.md": "[b](b)", "b.md": ""]
        let graph = WikiGraphBuilder.build(allPages: ["a.md", "b.md"], bodies: bodies)
        XCTAssertEqual(graph.edges.map(\.to), ["b.md"])
    }

    func testMarkdownLinkCaseInsensitive() {
        let bodies = ["a.md": "[B](B.MD)", "b.md": ""]
        let graph = WikiGraphBuilder.build(allPages: ["a.md", "b.md"], bodies: bodies)
        XCTAssertEqual(graph.edges.map(\.to), ["b.md"])
    }

    func testWikiLinkResolvesByStemAcrossFolders() {
        let bodies = ["a.md": "[[제목]]", "folder/제목.md": ""]
        let graph = WikiGraphBuilder.build(allPages: ["a.md", "folder/제목.md"], bodies: bodies)
        XCTAssertEqual(graph.edges.map(\.to), ["folder/제목.md"])
    }

    /// 이름 겹침 — 후보 2개 이상이면 사전순 첫 후보를 결정론적으로 채택하고 ambiguous로 표시.
    func testDuplicateTitleIsAmbiguousAndDeterministic() {
        let bodies = ["src.md": "[[중복]]", "a/중복.md": "", "b/중복.md": ""]
        let allPages = ["a/중복.md", "b/중복.md", "src.md"]
        let graph1 = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        let graph2 = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        XCTAssertEqual(graph1.ambiguousLinks.count, 1)
        XCTAssertEqual(graph1.ambiguousLinks[0].candidatePaths, ["a/중복.md", "b/중복.md"])
        XCTAssertEqual(graph1.edges.map(\.to), ["a/중복.md"])   // 사전순 첫 후보
        XCTAssertEqual(graph1.edges, graph2.edges)   // 결정론
    }

    func testSelfReferenceIsRemoved() {
        let bodies = ["a.md": "[[a]]"]
        let graph = WikiGraphBuilder.build(allPages: ["a.md"], bodies: bodies)
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertTrue(graph.unresolvedLinks.isEmpty)
        XCTAssertTrue(graph.ambiguousLinks.isEmpty)
    }

    /// 엣지 축약 — 같은 (from,to)에 여러 링크(문법 혼재)가 있으면 kinds 합집합 + weight 누적.
    func testEdgeCollapsesKindsAndWeight() {
        let bodies = ["a.md": "[[b]] ![[b]] [b](b.md)", "b.md": ""]
        let graph = WikiGraphBuilder.build(allPages: ["a.md", "b.md"], bodies: bodies)
        XCTAssertEqual(graph.edges.count, 1)
        let edge = graph.edges[0]
        XCTAssertEqual(edge.weight, 3)
        XCTAssertEqual(edge.kinds, [.wiki, .embed, .markdown])
    }

    func testUnresolvedLinkWhenTargetPageDoesNotExist() {
        let bodies = ["a.md": "[[없는페이지]]"]
        let graph = WikiGraphBuilder.build(allPages: ["a.md"], bodies: bodies)
        XCTAssertEqual(graph.unresolvedLinks.count, 1)
        XCTAssertEqual(graph.unresolvedLinks[0].rawTarget, "없는페이지")
        XCTAssertEqual(graph.unresolvedLinks[0].status, .unresolved)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    /// 501문서 절단 — 앞 500개만 노드, 501번째를 가리킨 링크는 outsideLimit이지 unresolved가 아니다(허위 unresolved 0).
    func testTruncatesAt500PagesAndClassifiesOutsideLimitNotUnresolved() {
        var allPages = (0..<501).map { String(format: "p%03d.md", $0) }
        allPages.sort()   // WikiPageLister는 이미 이름순 — 테스트도 동일 가정
        let last = allPages[500]   // 501번째(절단 밖)
        var bodies: [String: String] = [:]
        for path in allPages.prefix(500) { bodies[path] = "" }
        bodies[allPages[0]] = "[[\((last as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))]]"

        let graph = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        XCTAssertEqual(graph.stats.nodeCount, 500)
        XCTAssertEqual(graph.stats.droppedPageCount, 1)
        XCTAssertEqual(graph.stats.unresolvedCount, 0, "절단 밖 링크는 unresolved가 아니어야 함(허위 unresolved 금지)")
        XCTAssertEqual(graph.stats.outsideLimitCount, 1)
        XCTAssertEqual(graph.outsideLimitLinks.first?.rawTarget, (last as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))
    }

    /// 3001엣지 절단 — 사전순 앞 3000개만 채택, 결정론(2회 동일). 500개 문서 전부를 노드 상한
    /// 안에 유지한 채, 각 문서가 다른 문서 7개씩을 가리키게 해(500*7=3500) 엣지 상한만 넘긴다
    /// (노드 상한이 먼저 걸리면 엣지가 애초에 못 만들어지므로 노드는 상한 안쪽으로 고정).
    func testTruncatesAt3000EdgesDeterministically() {
        let nodeCount = 500
        let allPages = (0..<nodeCount).map { String(format: "p%03d.md", $0) }.sorted()
        var bodies: [String: String] = [:]
        for i in 0..<nodeCount {
            var body = ""
            for offset in 1...7 {
                let target = (i + offset) % nodeCount
                body += "[[\(String(format: "p%03d", target))]] "
            }
            bodies[allPages[i]] = body
        }

        let graph1 = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        let graph2 = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        XCTAssertEqual(graph1.stats.nodeCount, nodeCount)
        XCTAssertEqual(graph1.edges.count, WikiGraphBuilder.edgeLimit)
        XCTAssertGreaterThan(graph1.stats.droppedEdgeCount, 0)
        XCTAssertEqual(graph1.edges, graph2.edges, "절단은 결정론적이어야 함(같은 입력 → 같은 출력)")
    }
}
