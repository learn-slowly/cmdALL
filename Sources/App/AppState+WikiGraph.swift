import Foundation
import CoreGraphics

/// 위키 관계도 화면(WikiGraph) 상태 관리 — 로드는 1회 스냅샷(그래프+레이아웃), 시작 포커스는
/// 로드 완료 시 1회만 결정한다(계획 §관계도 시작 규칙). I/O는 `WikiGraphLoader`(actor)가 맡는다.
extension AppState {
    /// 관계도 시트 열기(진입점 공용).
    func requestWikiGraph() {
        showWikiGraph = true
        Task { await loadWikiGraph() }
    }

    /// 폴더 확인 → 로드 → 시작 포커스 결정을 한 번에 수행. 중복 로드는 무시(가드).
    @MainActor
    func loadWikiGraph(size: CGSize = CGSize(width: 900, height: 700)) async {
        guard let folderPath = settings.wikiFolder else {
            wikiGraphError = "위키 폴더가 설정되지 않았습니다."
            wikiGraphSnapshot = nil
            return
        }
        guard !wikiGraphBusy else { return }
        wikiGraphBusy = true
        wikiGraphError = nil
        defer { wikiGraphBusy = false }

        let root = URL(fileURLWithPath: folderPath)
        let snapshot = await wikiGraphLoader.load(root: root, size: size)
        wikiGraphSnapshot = snapshot
        wikiGraphFocusNotice = determineInitialFocus(snapshot: snapshot, wikiRoot: root)
    }

    /// 관계도에서 노드를 클릭했을 때 그 문서를 탭으로 연다(계획 AC "점 클릭 → 탭 열기").
    func openWikiGraphNode(_ nodeID: String) {
        guard let folderPath = settings.wikiFolder else { return }
        let url = URL(fileURLWithPath: folderPath).appendingPathComponent(nodeID)
        openDocument(at: url, inNewTab: true)
    }

    /// 시작 포커스 규칙(계획 §관계도 시작 규칙, stage 2 승인 — 4경우):
    /// 1) 활성 탭이 위키 루트 안 + 노드에 존재 → 그 노드 중심 1-hop.
    /// 2) 위키 루트 안이지만 절단으로 노드에서 빠짐 → 전체 보기 + 안내.
    /// 3) 활성 탭이 위키 루트 밖 → 전체 보기.
    /// 4) 탭 없음 → 전체 보기.
    private func determineInitialFocus(snapshot: WikiGraphSnapshot, wikiRoot: URL) -> String? {
        guard let activeURL = activeTab?.fileURL else {
            wikiGraphFocusedNodeID = nil
            return nil
        }
        let rootPath = wikiRoot.standardizedFileURL.path + "/"
        let activePath = activeURL.standardizedFileURL.path
        guard activePath.hasPrefix(rootPath) else {
            wikiGraphFocusedNodeID = nil
            return nil
        }
        let relative = String(activePath.dropFirst(rootPath.count))
        guard snapshot.graph.nodes.contains(where: { $0.id == relative }) else {
            wikiGraphFocusedNodeID = nil
            return "지금 보던 글은 글 수 상한(\(WikiGraphBuilder.pageLimit)개)에 걸려 이번 그림에 없습니다"
        }
        wikiGraphFocusedNodeID = relative
        return "'\((relative as NSString).lastPathComponent)' 글 주변을 보고 있습니다 — 전체 보기로 바꿀 수 있습니다"
    }
}
