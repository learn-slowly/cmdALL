import XCTest
@testable import CmdMD

/// 위키 이력 화면(WikiHistory) AppState 배선 — 1회 스냅샷 로드, diff 정확성(직접 편집
/// 오귀속 없음), 되돌리기 이벤트도 정확한 diff, legacy·유실 표시, 구 형식 로그 호환.
@MainActor
final class AppWikiHistoryStateTests: XCTestCase {
    var tempData: URL!
    var wikiDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
        app.settings.wikiFolder = wikiDir.path
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private func makeSource(_ body: String = "# 자료\n내용") -> URL {
        let url = wikiDir.appendingPathComponent("src-\(UUID().uuidString).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 핵심 A — 인제스트 적용 후 탭에서(또는 앱 밖에서) 직접 저장한 내용이 diff에 섞이지 않는다.
    func testApplyThenDirectSaveThenHistoryHasNoContamination() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "old".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "old", newBody: "merged", sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        // 인제스트 뒤 직접 편집·저장(탭 저장 또는 앱 밖 저장) 시뮬레이션.
        try "직접 고친 내용".write(to: page, atomically: true, encoding: .utf8)
        // 실제 시계 타이밍에 기대지 않고, 기록 시각보다 확실히 뒤인 mtime을 결정론적으로 지정한다
        // (파일시스템 mtime 해상도·초 단위 반올림 경합 방지).
        let entries = await app.wikiBackupStore.allEntries()
        let recordedDate = try XCTUnwrap(entries.first?.date)
        try FileManager.default.setAttributes(
            [.modificationDate: recordedDate.addingTimeInterval(30)], ofItemAtPath: page.path)

        await app.loadWikiHistory()
        let row = try XCTUnwrap(app.wikiHistoryRows.first)
        guard case .pair(let old, let new) = row.diffState else {
            return XCTFail("pair여야 함: \(row.diffState)")
        }
        XCTAssertEqual(old, "old")
        XCTAssertEqual(new, "merged")
        XCTAssertFalse(new.contains("직접 고친 내용"))
        // 직접 편집 이후이므로 힌트가 떠야 한다.
        XCTAssertTrue(app.wikiHistoryLikelyEditedAfter(row))
    }

    /// 핵심 B — 인제스트 → 되돌리기 → 이력에서 새로 생긴 "복원 전 자동 백업" 행이
    /// legacyNoResult가 아니라 pair(old=되돌리기 전, new=되돌린 결과)이고 isRestoreEvent == true.
    func testRestoreShowsPairNotLegacyWithRestoreEventFlag() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "old".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "old", newBody: "merged", sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        let entry = await app.wikiBackupStore.allEntries().first!
        let ok = await app.restoreWikiIngest(entry)
        XCTAssertTrue(ok)

        await app.loadWikiHistory()
        let restoreRow = try XCTUnwrap(app.wikiHistoryRows.first { $0.isRestoreEvent })
        guard case .pair(let old, let new) = restoreRow.diffState else {
            return XCTFail("legacyNoResult가 아니라 pair여야 함: \(restoreRow.diffState)")
        }
        XCTAssertEqual(old, "merged")   // 되돌리기 직전(=병합 결과)
        XCTAssertEqual(new, "old")      // 되돌린 결과
    }

    /// resultFile 도입 전 구 기록(recordResult 미호출)은 legacyNoResult로 정직하게 표시.
    func testLegacyEntryWithoutResultShowsLegacyNoResult() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        _ = try await app.wikiBackupStore.recordApply(pageURL: page, oldBody: "예전 내용", sourceName: "s.pdf")

        await app.loadWikiHistory()
        let row = try XCTUnwrap(app.wikiHistoryRows.first)
        guard case .legacyNoResult(let old) = row.diffState else {
            return XCTFail("legacyNoResult여야 함: \(row.diffState)")
        }
        XCTAssertEqual(old, "예전 내용")
    }

    /// 백업 파일이 사라진 경우(유실) — missingBackup + 되돌리기 비활성 판단 근거(diffState).
    func testMissingBackupFileShowsMissingBackup() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await app.wikiBackupStore.recordApply(pageURL: page, oldBody: "old", sourceName: "s.pdf")
        try await app.wikiBackupStore.recordResult(entryID: entry.id, newBody: "new")
        let backupFile = try XCTUnwrap(entry.backupFile)
        try FileManager.default.removeItem(
            at: tempData.appendingPathComponent("wiki-backups").appendingPathComponent(backupFile))

        await app.loadWikiHistory()
        let row = try XCTUnwrap(app.wikiHistoryRows.first)
        XCTAssertEqual(row.diffState, .missingBackup)
    }

    /// 되돌리기 왕복 — 이력 화면 경유(restoreFromWikiHistory)로도 실제 파일이 원복되고
    /// 스냅샷이 재캡처돼 새 되돌리기 행이 반영된다.
    func testRestoreFromWikiHistoryRoundTripUpdatesPageAndSnapshot() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "old".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "old", newBody: "merged", sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        await app.loadWikiHistory()
        let row = try XCTUnwrap(app.wikiHistoryRows.first)

        let ok = await app.restoreFromWikiHistory(row)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "old")
        XCTAssertTrue(app.wikiHistoryRows.contains { $0.isRestoreEvent })
    }

    /// 구 형식 로그(resultFile 키 없음) — 새 AppState 인스턴스로 다시 읽어도 항목 유실 없이
    /// legacyNoResult로 정확히 표시된다.
    func testLegacyFormatLogDecodingPreservesEntryCountInHistory() async throws {
        let backupFileName = "a-20260101-000000.md"
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","pageURL":"\(wikiDir.appendingPathComponent("a.md").absoluteString)",\
        "backupFile":"\(backupFileName)","sourceName":"s.pdf","date":"2026-01-01T00:00:00Z"}]
        """
        try legacyJSON.write(to: tempData.appendingPathComponent("wiki-ingest-log.json"),
                             atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempData.appendingPathComponent("wiki-backups"), withIntermediateDirectories: true)
        try "예전 백업".write(
            to: tempData.appendingPathComponent("wiki-backups").appendingPathComponent(backupFileName),
            atomically: true, encoding: .utf8)

        let app2 = AppState(dataDirectory: tempData)
        app2.settings.wikiFolder = wikiDir.path
        await app2.loadWikiHistory()

        XCTAssertEqual(app2.wikiHistoryRows.count, 1)
        guard case .legacyNoResult(let old) = app2.wikiHistoryRows[0].diffState else {
            return XCTFail("legacyNoResult여야 함: \(app2.wikiHistoryRows[0].diffState)")
        }
        XCTAssertEqual(old, "예전 백업")
    }
}
