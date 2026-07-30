import Foundation

/// 위키 관계도 순수 구성 — 링크 해석 + 절단 분류 + 엣지 축약/상한(디스크 접근 없음).
/// I/O(문서 목록·본문 읽기)는 `WikiGraphLoader`(actor)가 맡고, 여기엔 이미 읽은 값만 들어온다.
enum WikiGraphBuilder {
    /// 노드 상한(계획 §상한 절단 알고리즘).
    static let pageLimit = 500
    /// 엣지 상한(축약 후).
    static let edgeLimit = 3000

    /// - Parameters:
    ///   - allPages: 위키 루트 아래 전체 `.md` 상대경로(이미 이름순 — `WikiPageLister` 결과 그대로).
    ///     절단 이전 전체 목록이라 링크 해석 인덱스로 쓰인다(허위 unresolved 방지).
    ///   - bodies: 실제로 읽은 본문(대개 앞 500개까지). 읽기 실패했거나 절단 밖인 페이지는 키가 없다.
    static func build(allPages: [String], bodies: [String: String]) -> WikiGraph {
        let includedPages = Array(allPages.prefix(pageLimit))
        let includedSet = Set(includedPages)
        let droppedPageCount = max(0, allPages.count - pageLimit)
        let unreadablePageCount = includedPages.filter { bodies[$0] == nil }.count

        let nodes = includedPages.map { WikiGraphNode(id: $0) }

        var byStem: [String: [String]] = [:]
        for page in allPages {
            byStem[stemKey(page), default: []].append(page)
        }
        for key in byStem.keys { byStem[key] = byStem[key]!.sorted() }
        let allPagesLowerSet = Set(allPages.map { $0.lowercased() })

        var resolutions: [WikiLinkResolution] = []
        var edgeAccum: [String: (kinds: Set<WikiLinkKind>, weight: Int)] = [:]

        for page in includedPages {
            guard let body = bodies[page] else { continue }
            for raw in WikiLinkExtractor.links(in: body) {
                let candidates: [String]
                switch raw.kind {
                case .markdown:
                    candidates = resolveMarkdownTarget(raw.rawTarget, fromPage: page,
                                                       allPages: allPages, allPagesLower: allPagesLowerSet)
                case .wiki, .embed:
                    candidates = resolveWikiTarget(raw.rawTarget, byStem: byStem)
                }

                guard let resolved = candidates.first else {
                    resolutions.append(WikiLinkResolution(
                        fromPage: page, kind: raw.kind, rawTarget: raw.rawTarget,
                        candidatePaths: [], status: .unresolved))
                    continue
                }
                if resolved == page { continue }   // 자기참조 제거 — 문제 목록에도 안 남긴다.

                let status: WikiLinkResolution.Status = includedSet.contains(resolved) ? .resolved : .outsideLimit
                resolutions.append(WikiLinkResolution(
                    fromPage: page, kind: raw.kind, rawTarget: raw.rawTarget,
                    candidatePaths: candidates, status: status))

                if status == .resolved {
                    let key = "\(page)\u{0}\(resolved)"
                    var entry = edgeAccum[key] ?? (kinds: [], weight: 0)
                    entry.kinds.insert(raw.kind)
                    entry.weight += 1
                    edgeAccum[key] = entry
                }
            }
        }

        var edges = edgeAccum.map { key, value -> WikiGraphEdge in
            let parts = key.components(separatedBy: "\u{0}")
            return WikiGraphEdge(from: parts[0], to: parts[1], kinds: value.kinds, weight: value.weight)
        }
        edges.sort { $0.from != $1.from ? $0.from < $1.from : $0.to < $1.to }
        let droppedEdgeCount = max(0, edges.count - edgeLimit)
        if edges.count > edgeLimit {
            edges = Array(edges.prefix(edgeLimit))
        }

        let unresolvedLinks = resolutions.filter { $0.status == .unresolved }
        let outsideLimitLinks = resolutions.filter { $0.status == .outsideLimit }
        let ambiguousLinks = resolutions.filter { $0.isAmbiguous }

        let stats = WikiGraphStats(
            nodeCount: nodes.count, edgeCount: edges.count,
            unresolvedCount: unresolvedLinks.count, outsideLimitCount: outsideLimitLinks.count,
            ambiguousCount: ambiguousLinks.count, unreadablePageCount: unreadablePageCount,
            droppedPageCount: droppedPageCount, droppedEdgeCount: droppedEdgeCount)

        return WikiGraph(nodes: nodes, edges: edges,
                          unresolvedLinks: unresolvedLinks, outsideLimitLinks: outsideLimitLinks,
                          ambiguousLinks: ambiguousLinks, stats: stats)
    }

    // MARK: - 해석

    /// 마크다운 링크 — fromPage 기준 상대 경로(../·하위 폴더 포함), 확장자 생략 시 .md 보완,
    /// 대소문자 무시 비교. 경로가 유일하므로 후보는 보통 0 또는 1개.
    private static func resolveMarkdownTarget(_ raw: String, fromPage: String,
                                              allPages: [String], allPagesLower: Set<String>) -> [String] {
        let withExt = withMdExtensionIfMissing(raw)
        let fromDir = (fromPage as NSString).deletingLastPathComponent
        let combined = fromDir.isEmpty ? withExt : (fromDir as NSString).appendingPathComponent(withExt)
        let normalized = normalizePath(combined).lowercased()
        guard allPagesLower.contains(normalized) else { return [] }
        return allPages.filter { $0.lowercased() == normalized }.sorted()
    }

    /// 위키링크·임베드 — 파일명(stem) 기준, 폴더 무관(Obsidian 관례). 여러 폴더에 같은 이름이
    /// 있으면 후보 2개 이상(이름 겹침) → `isAmbiguous`.
    private static func resolveWikiTarget(_ raw: String, byStem: [String: [String]]) -> [String] {
        byStem[stemKey(raw)] ?? []
    }

    private static func stemKey(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func withMdExtensionIfMissing(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.contains(".") ? path : path + ".md"
    }

    private static func normalizePath(_ path: String) -> String {
        var stack: [String] = []
        for component in path.components(separatedBy: "/") {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(component)
            }
        }
        return stack.joined(separator: "/")
    }
}
