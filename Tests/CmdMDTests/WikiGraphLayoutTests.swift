import XCTest
@testable import CmdMD

/// `WikiGraphLayout` — 결정론적 force-directed 레이아웃(순수 함수).
final class WikiGraphLayoutTests: XCTestCase {
    private func makeGraph(nodeIDs: [String], edges: [(String, String)]) -> WikiGraph {
        let nodes = nodeIDs.map { WikiGraphNode(id: $0) }
        let graphEdges = edges.map { WikiGraphEdge(from: $0.0, to: $0.1, kinds: [.wiki], weight: 1) }
        let stats = WikiGraphStats(nodeCount: nodes.count, edgeCount: graphEdges.count,
                                   unresolvedCount: 0, outsideLimitCount: 0, ambiguousCount: 0,
                                   unreadablePageCount: 0, droppedPageCount: 0, droppedEdgeCount: 0)
        return WikiGraph(nodes: nodes, edges: graphEdges, unresolvedLinks: [],
                         outsideLimitLinks: [], ambiguousLinks: [], stats: stats)
    }

    func testZeroNodesReturnsEmptyPositions() {
        let graph = makeGraph(nodeIDs: [], edges: [])
        XCTAssertTrue(WikiGraphLayout.layout(graph, size: CGSize(width: 800, height: 600)).isEmpty)
    }

    func testOneNodeReturnsSinglePositionInBounds() {
        let graph = makeGraph(nodeIDs: ["a.md"], edges: [])
        let positions = WikiGraphLayout.layout(graph, size: CGSize(width: 800, height: 600))
        let point = try! XCTUnwrap(positions["a.md"])
        XCTAssertTrue((0...800).contains(point.x))
        XCTAssertTrue((0...600).contains(point.y))
    }

    func testDeterministicSameInputSameOutput() {
        let graph = makeGraph(nodeIDs: ["a", "b", "c", "d"],
                              edges: [("a", "b"), ("b", "c"), ("c", "d"), ("d", "a")])
        let size = CGSize(width: 800, height: 600)
        let p1 = WikiGraphLayout.layout(graph, size: size, seed: 7)
        let p2 = WikiGraphLayout.layout(graph, size: size, seed: 7)
        XCTAssertEqual(p1, p2)
    }

    func testAllPositionsWithinBounds() {
        let ids = (0..<40).map { "n\($0)" }
        var edges: [(String, String)] = []
        for i in 0..<ids.count where i > 0 { edges.append((ids[i - 1], ids[i])) }
        let graph = makeGraph(nodeIDs: ids, edges: edges)
        let size = CGSize(width: 800, height: 600)
        let positions = WikiGraphLayout.layout(graph, size: size)
        XCTAssertEqual(positions.count, ids.count)
        for point in positions.values {
            XCTAssertTrue((0...size.width).contains(point.x), "x \(point.x) 범위 밖")
            XCTAssertTrue((0...size.height).contains(point.y), "y \(point.y) 범위 밖")
        }
    }

    /// 분리 성분 — 서로 다른 연결 성분은 격자 셀로 분리되므로 좌표가 겹치지 않는다(각기 다른 사분면류 영역).
    func testSeparateComponentsDoNotOverlap() {
        let graph = makeGraph(
            nodeIDs: ["a1", "a2", "b1", "b2"],
            edges: [("a1", "a2"), ("b1", "b2")])
        let size = CGSize(width: 800, height: 600)
        let positions = WikiGraphLayout.layout(graph, size: size)
        let aPoints = [positions["a1"]!, positions["a2"]!]
        let bPoints = [positions["b1"]!, positions["b2"]!]
        // 각 컴포넌트는 서로 다른 격자 셀(가로 절반)에 배정되므로 x범위가 겹치지 않는다.
        let aRange = (aPoints.map(\.x).min()!)...(aPoints.map(\.x).max()!)
        let bRange = (bPoints.map(\.x).min()!)...(bPoints.map(\.x).max()!)
        XCTAssertFalse(aRange.overlaps(bRange), "서로 다른 연결 성분의 x범위가 겹치면 안 됨")
    }

    func testPerformanceUnder300NodesCompletesQuickly() {
        let ids = (0..<300).map { "n\($0)" }
        var edges: [(String, String)] = []
        for i in 0..<ids.count {
            edges.append((ids[i], ids[(i + 1) % ids.count]))
            edges.append((ids[i], ids[(i + 3) % ids.count]))
        }
        let graph = makeGraph(nodeIDs: ids, edges: edges)
        let start = Date()
        let positions = WikiGraphLayout.layout(graph, size: CGSize(width: 1200, height: 900))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(positions.count, 300)
        XCTAssertLessThan(elapsed, 3.0, "300노드 레이아웃이 너무 오래 걸림: \(elapsed)s")
    }
}
