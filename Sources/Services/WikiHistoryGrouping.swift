import Foundation

/// 위키 이력 화면의 순수 그룹핑 로직 — 값만 받아 diff 상태를 산출한다(디스크 접근 없음).
/// I/O(본문 스냅샷 캡처)는 `AppState+WikiHistory.loadWikiHistory()`가 1회 수행해 `bodies`로
/// 주입한다(계획 §이력 화면 순수/I-O 경계).
enum WikiHistoryGrouping {
    /// 이력 화면 한 줄.
    struct Row: Identifiable, Equatable {
        let entry: WikiIngestLogEntry
        let diffState: DiffState
        /// `sourceName == "복원 전 자동 백업"` 판정 — 뷰에서 배지로만 쓴다.
        let isRestoreEvent: Bool
        var id: UUID { entry.id }
    }

    /// 화면에 보여줄 diff 상태 — "이력 diff 계약" 표(계획 stage-03-revision.md)를 그대로 코드화.
    enum DiffState: Equatable {
        /// 정상 diff(인제스트·복원 공통). old/new는 backupFile/resultFile 본문.
        case pair(old: String, new: String)
        /// 새 페이지 생성 — old는 항상 빈 문자열(전부 초록 렌더용).
        case createdPage(new: String)
        /// 구 기록(resultFile == nil) — 정확한 비교 불가. old는 backupFile 본문(있으면).
        case legacyNoResult(old: String?)
        /// backupFile은 있는데 실제 파일이 사라짐 — 되돌리기 비활성.
        case missingBackup
    }

    /// - Parameters:
    ///   - entries: `WikiBackupStore.allEntries()`(이미 최신순) 그대로 — 여기서 재정렬하지 않는다.
    ///   - bodies: 백업/결과 파일명 → 본문 스냅샷(호출부가 1회 캡처해 주입).
    ///   - pageFilter: 특정 페이지만 볼 때의 URL. nil이면 전체.
    static func rows(entries: [WikiIngestLogEntry], bodies: [String: String],
                     pageFilter: URL?) -> [Row] {
        entries
            .filter { pageFilter == nil || $0.pageURL == pageFilter }
            .map { entry in
                let isRestore = entry.sourceName == "복원 전 자동 백업"
                let backupBody = entry.backupFile.flatMap { bodies[$0] }
                let resultBody = entry.resultFile.flatMap { bodies[$0] }
                let diffState: DiffState
                if entry.backupFile != nil && backupBody == nil {
                    // 로그엔 backupFile이 있는데 실제 파일을 못 찾음(유실) — 최우선으로 정직하게 표시.
                    diffState = .missingBackup
                } else if entry.resultFile == nil {
                    diffState = .legacyNoResult(old: backupBody)
                } else if entry.backupFile == nil {
                    diffState = .createdPage(new: resultBody ?? "")
                } else {
                    diffState = .pair(old: backupBody ?? "", new: resultBody ?? "")
                }
                return Row(entry: entry, diffState: diffState, isRestoreEvent: isRestore)
            }
    }
}
