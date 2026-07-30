import Foundation
import CoreGraphics

/// 위키 관계도(WikiGraph) 순수 모델 — 노드/엣지/링크 해석 결과. 전부 값 타입, I/O 없음.

/// 지원하는 링크 문법 3종(계획 §링크 추출·해석 계약, stage 2 승인).
enum WikiLinkKind: String, Codable, CaseIterable {
    case markdown   // [텍스트](경로.md)
    case wiki       // [[페이지]] / [[페이지|표시이름]]
    case embed      // ![[페이지]]
}

/// 문서 하나에서 뽑아낸 링크 원문(해석 전) — `WikiLinkExtractor`가 만든다.
struct WikiRawLink: Equatable {
    let kind: WikiLinkKind
    /// 실제로 열리는(=현재 렌더러가 내비게이션에 쓰는) 대상 문자열. `[[a|b]]`는 렌더러의
    /// 기존 동작(`MarkdownRenderer.processWikiLinks`)과 일치시켜 파이프 뒤쪽을 target으로 쓴다.
    let rawTarget: String
    /// 사람에게 보여줄 텍스트(파이프 앞쪽, 없으면 nil).
    let displayText: String?
}

/// 한 링크의 해석 결과 — `WikiGraphBuilder`가 만든다.
struct WikiLinkResolution: Equatable {
    let fromPage: String
    let kind: WikiLinkKind
    let rawTarget: String
    /// 경로 사전순. 0개=못 찾음, 2개 이상=이름 겹침(모호).
    let candidatePaths: [String]
    /// `candidatePaths.first` — 결정론적으로 사전순 첫 후보를 채택.
    var resolvedPath: String? { candidatePaths.first }
    var isAmbiguous: Bool { candidatePaths.count > 1 }
    let status: Status
    enum Status: String, Equatable {
        case resolved
        case unresolved     // 후보 0개 — 가리킨 문서를 못 찾음
        case outsideLimit   // 문서는 존재하지만 500개 상한 밖이라 이번 그림에 없음
    }
}

/// 관계도 노드 — 위키 루트 기준 상대경로가 고유 id.
struct WikiGraphNode: Identifiable, Equatable, Hashable {
    let id: String
    var displayName: String { (id as NSString).lastPathComponent }
}

/// 관계도 엣지(축약 후) — 같은 (from,to) 쌍의 여러 링크는 kinds 합집합 + weight로 뭉친다.
struct WikiGraphEdge: Identifiable, Equatable {
    let from: String
    let to: String
    let kinds: Set<WikiLinkKind>
    let weight: Int
    var id: String { "\(from)->\(to)" }
}

/// 관계도 상태줄·진단용 통계(계획 §관찰가능성).
struct WikiGraphStats: Equatable {
    let nodeCount: Int
    let edgeCount: Int
    let unresolvedCount: Int
    let outsideLimitCount: Int
    let ambiguousCount: Int
    let unreadablePageCount: Int
    let droppedPageCount: Int
    let droppedEdgeCount: Int
}

/// 순수 그래프 결과 — 레이아웃 전.
struct WikiGraph: Equatable {
    let nodes: [WikiGraphNode]
    let edges: [WikiGraphEdge]
    /// 연결 못 찾은 링크 상세(어느 글 → 어떤 이름).
    let unresolvedLinks: [WikiLinkResolution]
    /// 문서는 존재하지만 500개 상한 밖이라 이번 그림에 없는 링크 상세.
    let outsideLimitLinks: [WikiLinkResolution]
    /// 이름 겹침(모호) 링크 상세.
    let ambiguousLinks: [WikiLinkResolution]
    let stats: WikiGraphStats

    /// 특정 노드 기준 1-hop(양방향) 부분집합 — 관계도 "고른 글 주변만" 모드에 사용.
    func egoNodes(around id: String) -> Set<String> {
        var result: Set<String> = [id]
        for edge in edges {
            if edge.from == id { result.insert(edge.to) }
            if edge.to == id { result.insert(edge.from) }
        }
        return result
    }
}

/// actor 로더가 만드는 최종 산출물 — 그래프 + 레이아웃 좌표.
struct WikiGraphSnapshot: Equatable {
    let graph: WikiGraph
    /// 노드 id → 좌표(결정론적 레이아웃 결과).
    let positions: [String: CGPoint]
}
