import Foundation
import CoreGraphics

/// 위키 관계도 결정론적 force-directed 레이아웃(순수 함수, 디스크·실난수 없음).
/// 같은 그래프+size+seed → 항상 같은 좌표. 서로 다른 연결 성분은 격자 셀로 분리해 겹치지 않는다.
enum WikiGraphLayout {
    private static let iterations = 60
    private static let repulsion: CGFloat = 4000
    private static let springLength: CGFloat = 90
    private static let springStrength: CGFloat = 0.04
    private static let damping: CGFloat = 0.85
    private static let padding: CGFloat = 24

    static func layout(_ graph: WikiGraph, size: CGSize, seed: UInt64 = 42) -> [String: CGPoint] {
        guard !graph.nodes.isEmpty, size.width > 0, size.height > 0 else { return [:] }
        let components = connectedComponents(graph)
        let cellsPerRow = max(1, Int(ceil(sqrt(Double(components.count)))))
        let rows = max(1, Int(ceil(Double(components.count) / Double(cellsPerRow))))
        let cellWidth = size.width / CGFloat(cellsPerRow)
        let cellHeight = size.height / CGFloat(rows)
        let cellSize = CGSize(width: cellWidth, height: cellHeight)

        var positions: [String: CGPoint] = [:]
        for (index, component) in components.enumerated() {
            let col = index % cellsPerRow
            let row = index / cellsPerRow
            let cellOrigin = CGPoint(x: CGFloat(col) * cellWidth, y: CGFloat(row) * cellHeight)
            let laidOut = layoutComponent(component, edges: graph.edges, cellSize: cellSize,
                                          seed: seed &+ UInt64(index))
            for (id, point) in laidOut {
                positions[id] = CGPoint(x: cellOrigin.x + point.x, y: cellOrigin.y + point.y)
            }
        }
        return positions
    }

    /// 한 연결 성분을 자기 셀 안에서만 배치(결정론적 초기 배치 + 고정 반복 횟수의 힘 시뮬레이션).
    private static func layoutComponent(_ nodeIDs: [String], edges: [WikiGraphEdge],
                                        cellSize: CGSize, seed: UInt64) -> [String: CGPoint] {
        let n = nodeIDs.count
        guard n > 0 else { return [:] }
        let center = CGPoint(x: cellSize.width / 2, y: cellSize.height / 2)
        if n == 1 { return [nodeIDs[0]: center] }

        let padX = max(0, min(padding, cellSize.width / 2 - 1))
        let padY = max(0, min(padding, cellSize.height / 2 - 1))
        let radius = max(min(cellSize.width, cellSize.height) / 2 - max(padX, padY), 10)
        let angleOffset = Double(seed % 360) * .pi / 180

        var index: [String: Int] = [:]
        var pos: [CGPoint] = Array(repeating: .zero, count: n)
        for (i, id) in nodeIDs.enumerated() {
            index[id] = i
            let angle = angleOffset + 2 * Double.pi * Double(i) / Double(n)
            pos[i] = CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                             y: center.y + radius * CGFloat(sin(angle)))
        }

        let localEdges: [(Int, Int)] = edges.compactMap { edge in
            guard let a = index[edge.from], let b = index[edge.to], a != b else { return nil }
            return (a, b)
        }

        for _ in 0..<iterations {
            var displacement = Array(repeating: CGPoint.zero, count: n)

            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = pos[i].x - pos[j].x
                    var dy = pos[i].y - pos[j].y
                    var distSq = dx * dx + dy * dy
                    if distSq < 0.0001 {
                        // 정확히 겹치면 index 차 기반으로 결정론적인 미세 오프셋을 준다(0으로 나눔 방지).
                        dx = CGFloat(i - j) * 0.01 + 0.01
                        dy = 0.01
                        distSq = dx * dx + dy * dy
                    }
                    let dist = sqrt(distSq)
                    let force = repulsion / distSq
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    displacement[i].x += fx; displacement[i].y += fy
                    displacement[j].x -= fx; displacement[j].y -= fy
                }
            }
            for (a, b) in localEdges {
                let dx = pos[b].x - pos[a].x
                let dy = pos[b].y - pos[a].y
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let force = (dist - springLength) * springStrength
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                displacement[a].x += fx; displacement[a].y += fy
                displacement[b].x -= fx; displacement[b].y -= fy
            }
            for i in 0..<n {
                var newPos = CGPoint(x: pos[i].x + displacement[i].x * damping,
                                     y: pos[i].y + displacement[i].y * damping)
                newPos.x = min(max(newPos.x, padX), cellSize.width - padX)
                newPos.y = min(max(newPos.y, padY), cellSize.height - padY)
                pos[i] = newPos
            }
        }

        var result: [String: CGPoint] = [:]
        for (i, id) in nodeIDs.enumerated() { result[id] = pos[i] }
        return result
    }

    /// 연결 성분(무방향, 엣지 방향 무시) — 결정론적 순서: 노드 id 사전순으로 순회하며 BFS,
    /// 컴포넌트는 (크기 내림차순, 대표 id 오름차순)으로 정렬해 항상 같은 격자 배치가 나오게 한다.
    private static func connectedComponents(_ graph: WikiGraph) -> [[String]] {
        var adjacency: [String: Set<String>] = [:]
        for node in graph.nodes { adjacency[node.id] = [] }
        for edge in graph.edges {
            adjacency[edge.from, default: []].insert(edge.to)
            adjacency[edge.to, default: []].insert(edge.from)
        }
        var visited: Set<String> = []
        var components: [[String]] = []
        for node in graph.nodes.sorted(by: { $0.id < $1.id }) {
            guard !visited.contains(node.id) else { continue }
            var queue = [node.id]
            var comp: [String] = []
            visited.insert(node.id)
            var head = 0
            while head < queue.count {
                let current = queue[head]; head += 1
                comp.append(current)
                for neighbor in (adjacency[current] ?? []).sorted() where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(comp.sorted())
        }
        return components.sorted { a, b in
            a.count != b.count ? a.count > b.count : (a.first ?? "") < (b.first ?? "")
        }
    }
}
