import XCTest
@testable import CmdMD

/// `WikiHistoryGrouping` — 이력 화면 diff 상태 산출(순수 함수, 디스크 접근 없음).
final class WikiHistoryGroupingTests: XCTestCase {
    private let pageA = URL(fileURLWithPath: "/wiki/a.md")
    private let pageB = URL(fileURLWithPath: "/wiki/b.md")

    private func entry(page: URL, backupFile: String?, resultFile: String?,
                        sourceName: String = "s.pdf", date: Date = Date()) -> WikiIngestLogEntry {
        WikiIngestLogEntry(id: UUID(), pageURL: page, backupFile: backupFile,
                           resultFile: resultFile, sourceName: sourceName, date: date)
    }

    func testPairForNormalIngestWithBothFiles() {
        let e = entry(page: pageA, backupFile: "b1", resultFile: "r1")
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: ["b1": "old body", "r1": "new body"],
                                            pageFilter: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].diffState, .pair(old: "old body", new: "new body"))
        XCTAssertFalse(rows[0].isRestoreEvent)
    }

    func testCreatedPageWhenBackupFileNilButResultPresent() {
        let e = entry(page: pageA, backupFile: nil, resultFile: "r1")
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: ["r1": "생성된 본문"], pageFilter: nil)
        XCTAssertEqual(rows[0].diffState, .createdPage(new: "생성된 본문"))
    }

    func testLegacyNoResultWhenResultFileNil() {
        let e = entry(page: pageA, backupFile: "b1", resultFile: nil)
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: ["b1": "예전 내용"], pageFilter: nil)
        XCTAssertEqual(rows[0].diffState, .legacyNoResult(old: "예전 내용"))
    }

    func testLegacyNoResultWithNoBackupFileEither() {
        // 아주 드문 구 형식 새 페이지 항목(둘 다 nil) — old도 nil.
        let e = entry(page: pageA, backupFile: nil, resultFile: nil)
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: [:], pageFilter: nil)
        XCTAssertEqual(rows[0].diffState, .legacyNoResult(old: nil))
    }

    func testMissingBackupWhenBackupFileRecordedButBodyAbsent() {
        // backupFile은 로그에 있지만 실제 파일이 사라진 경우 — resultFile 유무와 무관하게 최우선.
        let e = entry(page: pageA, backupFile: "b-gone", resultFile: "r1")
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: ["r1": "new"], pageFilter: nil)
        XCTAssertEqual(rows[0].diffState, .missingBackup)
    }

    func testIsRestoreEventTrueForAutoBackupSourceName() {
        let e = entry(page: pageA, backupFile: "b1", resultFile: "r1", sourceName: "복원 전 자동 백업")
        let rows = WikiHistoryGrouping.rows(entries: [e], bodies: ["b1": "before", "r1": "after"],
                                            pageFilter: nil)
        XCTAssertTrue(rows[0].isRestoreEvent)
        XCTAssertEqual(rows[0].diffState, .pair(old: "before", new: "after"))
    }

    func testPageFilterKeepsOnlyMatchingPage() {
        let e1 = entry(page: pageA, backupFile: "b1", resultFile: "r1")
        let e2 = entry(page: pageB, backupFile: "b2", resultFile: "r2")
        let rows = WikiHistoryGrouping.rows(entries: [e1, e2],
                                            bodies: ["b1": "1", "r1": "1n", "b2": "2", "r2": "2n"],
                                            pageFilter: pageA)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].entry.pageURL, pageA)
    }

    func testNoFilterKeepsAllPages() {
        let e1 = entry(page: pageA, backupFile: "b1", resultFile: "r1")
        let e2 = entry(page: pageB, backupFile: "b2", resultFile: "r2")
        let rows = WikiHistoryGrouping.rows(entries: [e1, e2],
                                            bodies: ["b1": "1", "r1": "1n", "b2": "2", "r2": "2n"],
                                            pageFilter: nil)
        XCTAssertEqual(rows.count, 2)
    }

    func testOrderIsPreservedNotResorted() {
        // rows()는 재정렬하지 않는다 — 호출부(allEntries(), 이미 최신순)의 순서를 그대로 따른다.
        let newer = entry(page: pageA, backupFile: "b1", resultFile: "r1", date: Date())
        let older = entry(page: pageA, backupFile: "b2", resultFile: "r2", date: Date(timeIntervalSinceNow: -100))
        let rows = WikiHistoryGrouping.rows(entries: [newer, older],
                                            bodies: ["b1": "1", "r1": "1n", "b2": "2", "r2": "2n"],
                                            pageFilter: nil)
        XCTAssertEqual(rows.map(\.entry.id), [newer.id, older.id])
    }

    func testEmptyEntriesProducesEmptyRows() {
        XCTAssertTrue(WikiHistoryGrouping.rows(entries: [], bodies: [:], pageFilter: nil).isEmpty)
    }
}
