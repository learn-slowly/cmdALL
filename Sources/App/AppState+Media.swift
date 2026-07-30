import Foundation
import AVFoundation
import AppKit

extension AppState {

    // MARK: - 미디어 플레이어 소유권
    // 시맨틱(사용자 결정, 2026-07-03): 탭 전환 = 재생 유지(백그라운드 청취),
    // 탭 닫기·메인 창 닫기 = 정지.

    /// 미디어 탭의 플레이어를 돌려준다 — 없으면 만들고, url이 바뀌었으면 이전 것을 정지 후 교체.
    /// 같은 탭을 여러 창이 보여줘도 인스턴스는 하나(컨트롤 동기화·고아 불가).
    /// 뷰가 직접 AVPlayer를 만들지 않는 것이 규칙 — 레지스트리 밖 플레이어가 없어야
    /// 탭 닫기·창 닫기 정지가 전수 보장된다(실측 근거, 2026-07-03: 창 2개가
    /// 같은 탭을 보여줄 때 뷰마다 따로 만들면 등록에서 밀려난 고아가 계속 울렸다).
    func mediaPlayer(forTab tabID: UUID, url: URL) -> AVPlayer {
        if let existing = mediaPlayers[tabID],
           (existing.currentItem?.asset as? AVURLAsset)?.url == url {
            return existing
        }
        mediaPlayers[tabID]?.pause()
        let player = AVPlayer(url: url)
        mediaPlayers[tabID] = player
        return player
    }

    /// 모든 미디어 플레이어를 정지한다(창 닫기 — 메뉴바 상주 앱이라 창은 숨겨질 뿐 뷰가 살아 있다).
    func pauseAllMediaPlayers() {
        for player in mediaPlayers.values { player.pause() }
    }
    /// 듀얼 페인 칸 미리보기 미디어만 정지(탭 플레이어는 안 건드림) — 듀얼 페인을 끌 때·
    /// "큰 화면에서 보기"로 승격할 때 씀(closePeekFile은 removeValue로 완전히 정리, 여긴 일시정지만
    /// — 나중에 같은 파일을 다시 칸에서 열면 이어서 재생되도록 레지스트리 항목은 남긴다).
    func pauseAllPaneMediaPlayers() {
        for tabID in panePeekMediaTabIDs { mediaPlayers[tabID]?.pause() }
    }

    func closeTabWithConfirmation(_ tab: EditorTab) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Your changes to \"\(tab.displayTitle)\" will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await saveCurrentDocument()
                closeTab(tab)
            }
        case .alertSecondButtonReturn:
            closeTab(tab)
        default:
            break
        }
    }

    func closeOtherTabs(except tab: EditorTab) {
        let otherTabs = tabs.filter { $0.id != tab.id && !$0.isPinned }
        for t in otherTabs {
            closeTab(t)
        }
    }

    func closeTabsToRight(of tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let tabsToRight = tabs.suffix(from: index + 1).filter { !$0.isPinned }
        for t in tabsToRight {
            closeTab(t)
        }
    }

    /// 핀 고정을 제외한 모든 탭을 닫는다. 더티 탭이 있고 확인 설정이 켜져 있으면
    /// 요약 알림 1회(모두 저장/저장 안 함/취소 — 개별 확인 연타 대신). 저장에
    /// 실패했거나 저장할 곳이 없는(URL 없는) 더티 탭은 닫지 않고 남긴다.
    func closeAllTabs() {
        let targets = tabs.filter { !$0.isPinned }
        guard !targets.isEmpty else { return }
        let dirtyTargets = targets.filter { isTabDirty($0) }

        guard !dirtyTargets.isEmpty, settings.confirmBeforeClosingDirtyTabs else {
            targets.forEach { closeTab($0) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "저장 안 된 변경이 있는 탭이 \(dirtyTargets.count)개 있습니다."
        alert.informativeText = "저장하지 않고 닫으면 변경 내용이 사라집니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "모두 저장 후 닫기")
        alert.addButton(withTitle: "저장 안 하고 닫기")
        alert.addButton(withTitle: "취소")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                var keptTabIds = Set<UUID>()
                for tab in dirtyTargets {
                    // 저장 도중 사용자가 직접 닫은 탭은 건너뛴다(실패 집계 아님).
                    guard tabs.contains(where: { $0.id == tab.id }) else { continue }
                    let saved = await saveDocument(forTabId: tab.id)
                    if !saved { keptTabIds.insert(tab.id) }
                }
                for tab in targets where !keptTabIds.contains(tab.id) {
                    closeTab(tab)
                }
                if !keptTabIds.isEmpty {
                    showToast("저장하지 못한 탭 \(keptTabIds.count)개는 남겨뒀습니다")
                }
            }
        case .alertSecondButtonReturn:
            targets.forEach { closeTab($0) }
        default:
            break
        }
    }
}
