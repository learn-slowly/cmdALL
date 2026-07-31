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

    /// 회귀 테스트(레고님 실사용 스크린샷 결함): 큰 성분(노드 30개)은 외톨이(노드 1개, 최소
    /// 가중치 바닥 적용) 하나보다 훨씬 넓은 사각형을 배정받아야 한다. 예전 코드는 성분
    /// "개수"만 보고 모든 성분에 동일 크기 칸을 줘서, 큰 성분이 외톨이와 같은 칸에 눌려
    /// 노드끼리 다 겹치는 문제가 있었다(레고님 스크린샷 재현). 힘 시뮬레이션 물리(스프링
    /// 길이 등)에 좌우되지 않도록 면적 배정 자체(`squarify`)를 직접 검증한다.
    func testLargeComponentGetsProportionallyMoreAreaThanSingleton() {
        let weights: [Double] = [30, 3, 3, 3, 3, 3] // 30노드 성분 + 외톨이 5개(최소 가중치 3)
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let rects = WikiGraphLayout.squarify(weights: weights, in: rect)
        XCTAssertEqual(rects.count, weights.count)

        let totalArea = Double(rect.width * rect.height)
        for (rect, weight) in zip(rects, weights) {
            let expectedShare = weight / weights.reduce(0, +)
            let actualShare = Double(rect.width * rect.height) / totalArea
            XCTAssertEqual(actualShare, expectedShare, accuracy: 0.01,
                           "가중치 \(weight)의 실제 면적 비율(\(actualShare))이 기대치(\(expectedShare))와 다름")
        }

        let bigArea = Double(rects[0].width * rects[0].height)
        let singletonArea = Double(rects[1].width * rects[1].height)
        XCTAssertGreaterThan(bigArea, singletonArea * 8,
                             "30노드 성분이 외톨이보다 8배 이상 넓은 칸을 받아야 함(옛 균등분할 버그 재발 의심)")

        // 사각형들이 서로 겹치지 않고 원래 rect를 정확히 채우는지(면적 합 보존)도 함께 확인.
        let sumOfAreas = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(sumOfAreas, totalArea, accuracy: 1.0)
    }

    /// 통합 수준 확인: 실제 힘 시뮬레이션까지 거쳐도 큰 성분의 노드들이 외톨이 성분보다
    /// 훨씬 넓게 퍼지는지(옛 버그처럼 캔버스 한구석에 짜부라지지 않는지) 재확인한다.
    func testLargeComponentSpreadsWiderThanUniformDivisionWouldAllow() {
        let bigIDs = (0..<30).map { "big\($0)" }
        var edges: [(String, String)] = []
        for i in 0..<bigIDs.count where i > 0 { edges.append((bigIDs[i - 1], bigIDs[i])) }
        let singletonIDs = (0..<20).map { "solo\($0)" }
        let graph = makeGraph(nodeIDs: bigIDs + singletonIDs, edges: edges)
        let size = CGSize(width: 1200, height: 900)
        let positions = WikiGraphLayout.layout(graph, size: size)

        let bigPoints = bigIDs.compactMap { positions[$0] }
        XCTAssertEqual(bigPoints.count, bigIDs.count)
        let bigMinX = bigPoints.map(\.x).min()!, bigMaxX = bigPoints.map(\.x).max()!
        let bigMinY = bigPoints.map(\.y).min()!, bigMaxY = bigPoints.map(\.y).max()!
        let bigArea = Double(bigMaxX - bigMinX) * Double(bigMaxY - bigMinY)

        // 옛 코드라면 성분 21개(1+20)를 5x5 격자로 나눠 칸 하나가 240x180=43200이었다
        // (전부 균등 분할). 새 배정은 그보다 훨씬 넓어야 한다.
        let oldUniformCellArea = 43200.0
        XCTAssertGreaterThan(bigArea, oldUniformCellArea * 3,
                             "큰 성분이 옛 균등분할 칸(43200)의 3배도 못 퍼짐 — 겹침 버그 재발 의심")
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
