import Foundation

/// 위키 이력 화면(WikiHistory) 상태 관리 — 로드는 1회 스냅샷 캡처, 행 클릭 재읽기 금지
/// (계획 §이력 화면 순수/I-O 경계). 순수 그룹핑은 `WikiHistoryGrouping`이 맡는다.
extension AppState {
    /// 이력 시트 열기(진입점 공용) — 특정 글만 볼지 필터 지정 가능.
    func requestWikiHistory(pageFilter: URL? = nil) {
        wikiHistoryPageFilter = pageFilter
        showWikiHistory = true
        Task { await loadWikiHistory() }
    }

    /// `allEntries()` 직후 backup/result 본문과 각 페이지 마지막 저장 시각을 1회 캡처해
    /// 순수 `WikiHistoryGrouping.rows`에 주입한다. 새로고침 버튼과 되돌리기 성공 직후에만
    /// 다시 호출한다 — 행 클릭으로는 재읽기하지 않는다.
    @MainActor
    func loadWikiHistory() async {
        wikiHistoryBusy = true
        wikiHistoryError = nil
        defer { wikiHistoryBusy = false }
        let entries = await wikiBackupStore.allEntries()
        let bodies = await wikiBackupStore.snapshotBodies(for: entries)
        var mtimes: [URL: Date] = [:]
        for pageURL in Set(entries.map(\.pageURL)) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: pageURL.path),
               let modified = attrs[.modificationDate] as? Date {
                mtimes[pageURL] = modified
            }
        }
        wikiHistoryKnownPages = Set(entries.map(\.pageURL))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        wikiHistoryPageMTimes = mtimes
        wikiHistoryRows = WikiHistoryGrouping.rows(entries: entries, bodies: bodies,
                                                    pageFilter: wikiHistoryPageFilter)
    }

    /// 마지막 기록보다 파일 저장 시각이 새로우면 "기록 이후 직접 고쳐진 것 같습니다" 힌트(AC 11).
    func wikiHistoryLikelyEditedAfter(_ row: WikiHistoryGrouping.Row) -> Bool {
        guard let mtime = wikiHistoryPageMTimes[row.entry.pageURL] else { return false }
        return mtime > row.entry.date
    }

    /// 이력 화면에서 되돌리기 — 기존 `restoreWikiIngest`를 재사용하고, 성공 시에만
    /// 스냅샷을 재캡처한다(계획 AC 6·12).
    @MainActor
    func restoreFromWikiHistory(_ row: WikiHistoryGrouping.Row) async -> Bool {
        let ok = await restoreWikiIngest(row.entry)
        if ok { await loadWikiHistory() }
        return ok
    }
}
