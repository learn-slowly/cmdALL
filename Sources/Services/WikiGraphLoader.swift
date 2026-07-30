import Foundation
import CoreGraphics

/// 위키 관계도 I/O 경계 — 문서 목록·본문 읽기를 한 번의 비동기 호출로 묶어 순수
/// `WikiGraphBuilder`/`WikiGraphLayout`에 넘긴다. 상태 없는 actor(형제 위키 서비스와 동일 경계).
actor WikiGraphLoader {
    /// 문서당 읽기 상한 — 이보다 크면 "읽지 못한 파일"로 집계하고 노드는 유지한다.
    static let bodySizeLimit = 1_000_000

    func load(root: URL, size: CGSize) async -> WikiGraphSnapshot {
        let allPages = WikiPageLister.relativePages(under: root)
        let included = Array(allPages.prefix(WikiGraphBuilder.pageLimit))

        var bodies: [String: String] = [:]
        for page in included {
            let url = root.appendingPathComponent(page)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[.size] as? Int, fileSize <= Self.bodySizeLimit,
                  let body = try? String(contentsOf: url, encoding: .utf8) else {
                continue   // 읽기 실패·용량 초과 — bodies에 키가 없으므로 builder가 unreadable로 집계.
            }
            bodies[page] = body
        }

        let graph = WikiGraphBuilder.build(allPages: allPages, bodies: bodies)
        let positions = WikiGraphLayout.layout(graph, size: size)
        return WikiGraphSnapshot(graph: graph, positions: positions)
    }
}
