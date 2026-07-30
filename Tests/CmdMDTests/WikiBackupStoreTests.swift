import XCTest
@testable import CmdMD

/// 위키 백업 저장소 — 덮어쓰기 직전 본 백업·기록·복원(스펙 §2.4). 볼트 밖(앱 데이터
/// 디렉터리)에만 쓴다.
final class WikiBackupStoreTests: XCTestCase {
    var dataDir: URL!
    var wikiDir: URL!

    override func setUp() {
        super.setUp()
        dataDir = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(dataDir)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    func testRecordApplySavesBackupAndLog() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: "# 이전 본문", sourceName: "논문.pdf")

        XCTAssertNotNil(entry.backupFile)
        let backup = dataDir.appendingPathComponent("wiki-backups")
            .appendingPathComponent(entry.backupFile!)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "# 이전 본문")

        let entries = await store.allEntries()
        XCTAssertEqual(entries, [entry])
        // 로그 영속 — 새 인스턴스로 다시 읽힌다.
        let reloaded = WikiBackupStore(directory: dataDir)
        let persisted = await reloaded.allEntries()
        XCTAssertEqual(persisted, [entry])
    }

    func testRecordApplyNewPageHasNoBackupFile() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("새주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: nil, sourceName: "논문.pdf")
        XCTAssertNil(entry.backupFile)
    }

    func testRestoreExistingPageRoundTrip() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)

        let entry = try await store.recordApply(pageURL: page, oldBody: "# 이전", sourceName: "s.pdf")
        try "# 병합 후".write(to: page, atomically: true, encoding: .utf8)   // 적용 시뮬레이션

        try await store.restore(entry)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 이전")
        // 왕복 안전 — 복원 직전의 "# 병합 후" 본도 자동 백업으로 기록된다.
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 2)
    }

    func testRestoreNewPageTrashesFile() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("새주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: nil, sourceName: "s.pdf")
        try "# 새 페이지".write(to: page, atomically: true, encoding: .utf8)  // 적용 시뮬레이션

        try await store.restore(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.path))   // 휴지통 이동(삭제 아님)
    }

    func testAllEntriesNewestFirst() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let p1 = wikiDir.appendingPathComponent("a.md")
        let p2 = wikiDir.appendingPathComponent("b.md")
        let e1 = try await store.recordApply(pageURL: p1, oldBody: "1", sourceName: "s1")
        let e2 = try await store.recordApply(pageURL: p2, oldBody: "2", sourceName: "s2")
        let entries = await store.allEntries()
        XCTAssertEqual(entries.map(\.id), [e2.id, e1.id])
    }

    func testRecordApplyThrowsWhenLogUnwritable() async throws {
        let store = WikiBackupStore(directory: dataDir)
        // 로그 파일 자리를 디렉터리로 점유해 쓰기를 결정적으로 실패시킨다.
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent("wiki-ingest-log.json"),
            withIntermediateDirectories: true)
        do {
            _ = try await store.recordApply(pageURL: wikiDir.appendingPathComponent("p.md"),
                                            oldBody: "x", sourceName: "s")
            XCTFail("에러여야 함")
        } catch { }
        let entries = await store.allEntries()
        XCTAssertTrue(entries.isEmpty)   // 실패한 기록은 로그에 남지 않는다
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: dataDir.appendingPathComponent("wiki-backups").path)
        XCTAssertTrue(backups.isEmpty)   // 고아 백업도 남지 않는다
    }

    // MARK: - resultFile(결과 스냅샷) — 계획 stage-03-revision.md §결과 스냅샷 계약

    /// 1. 구 형식 호환 — resultFile 키 없는 구 로그를 그대로 읽어도 항목 유실 없음.
    func testLegacyLogWithoutResultFileDecodesWithNilResultFile() async throws {
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","pageURL":"\(wikiDir.appendingPathComponent("a.md").absoluteString)",\
        "backupFile":"a-20260101-000000.md","sourceName":"s.pdf","date":"2026-01-01T00:00:00Z"}]
        """
        try legacyJSON.write(to: dataDir.appendingPathComponent("wiki-ingest-log.json"),
                             atomically: true, encoding: .utf8)
        let store = WikiBackupStore(directory: dataDir)
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].resultFile)
        XCTAssertEqual(entries[0].backupFile, "a-20260101-000000.md")
    }

    /// 2. 적용 경로 왕복 내구성 — recordResult 후 새 인스턴스에서도 resultFile·본문이 보존.
    func testRecordResultPersistsAcrossNewInstance() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: "old", sourceName: "s.pdf")
        try await store.recordResult(entryID: entry.id, newBody: "new body")

        let reloaded = WikiBackupStore(directory: dataDir)
        let entries = await reloaded.allEntries()
        XCTAssertEqual(entries.count, 1)
        let resultFile = try XCTUnwrap(entries[0].resultFile)
        let body = try String(
            contentsOf: dataDir.appendingPathComponent("wiki-backups").appendingPathComponent(resultFile),
            encoding: .utf8)
        XCTAssertEqual(body, "new body")
    }

    /// 3. persist 실패 롤백 — 메모리 entry가 resultFile==nil로 되돌아가고 고아 result 파일 없음.
    func testRecordResultPersistFailureRollsBackAndLeavesNoOrphan() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: "old", sourceName: "s.pdf")
        // 성공적으로 기록된 로그 파일을 지우고 그 자리를 디렉터리로 점유해 이후 persist를 결정적으로 실패시킨다.
        let logURL = dataDir.appendingPathComponent("wiki-ingest-log.json")
        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        do {
            try await store.recordResult(entryID: entry.id, newBody: "new")
            XCTFail("에러여야 함")
        } catch { }
        let entries = await store.allEntries()
        XCTAssertNil(entries.first?.resultFile)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: dataDir.appendingPathComponent("wiki-backups").path)
        XCTAssertFalse(backups.contains { $0.contains("-result") })
    }

    /// 4. 결과 파일 쓰기 실패 — entry 미변경(legacy), 부분 파일 없음, 로그 파일 내용 불변.
    func testRecordResultFileWriteFailureLeavesEntryLegacy() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: "old", sourceName: "s.pdf")
        let backupsDir = dataDir.appendingPathComponent("wiki-backups")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backupsDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupsDir.path) }
        do {
            try await store.recordResult(entryID: entry.id, newBody: "new")
            XCTFail("에러여야 함")
        } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupsDir.path)
        let entries = await store.allEntries()
        XCTAssertNil(entries.first?.resultFile)
        XCTAssertEqual(entries.count, 1)
    }

    /// 5. 복원 경로 — restore가 만든 "복원 전 자동 백업" 항목도 backupFile/resultFile 쌍을 갖는다.
    func testRestoreRecordsResultSnapshotForAutoBackupEntry() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        try "A".write(to: page, atomically: true, encoding: .utf8)
        let entry = try await store.recordApply(pageURL: page, oldBody: "A", sourceName: "s.pdf")
        try "B".write(to: page, atomically: true, encoding: .utf8)   // 적용 시뮬레이션

        try await store.restore(entry)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "A")   // (i)

        let entries = await store.allEntries()
        let autoEntry = try XCTUnwrap(entries.first { $0.sourceName == "복원 전 자동 백업" })
        let backupBody = try String(
            contentsOf: dataDir.appendingPathComponent("wiki-backups")
                .appendingPathComponent(XCTUnwrap(autoEntry.backupFile)),
            encoding: .utf8)
        XCTAssertEqual(backupBody, "B")   // (ii)
        let resultBody = try String(
            contentsOf: dataDir.appendingPathComponent("wiki-backups")
                .appendingPathComponent(XCTUnwrap(autoEntry.resultFile)),
            encoding: .utf8)
        XCTAssertEqual(resultBody, "A")   // (iii)

        let reloaded = WikiBackupStore(directory: dataDir)
        let reloadedEntries = await reloaded.allEntries()
        XCTAssertEqual(reloadedEntries.count, entries.count)   // (iv)
        XCTAssertTrue(reloadedEntries.contains { $0.id == autoEntry.id && $0.resultFile == autoEntry.resultFile })
    }

    /// 6. 복원 중 파일 쓰기 실패 — "복원 전 자동 백업" 항목은 남되 resultFile==nil, 고아 result 파일 없음.
    func testRestoreFileWriteFailureLeavesAutoBackupEntryLegacy() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        try "A".write(to: page, atomically: true, encoding: .utf8)
        let entry = try await store.recordApply(pageURL: page, oldBody: "A", sourceName: "s.pdf")
        try "B".write(to: page, atomically: true, encoding: .utf8)

        // 대상 페이지 폴더를 읽기 전용으로 만들어 복원 파일 쓰기를 결정적으로 실패시킨다.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: wikiDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wikiDir.path) }
        do {
            try await store.restore(entry)
            XCTFail("에러여야 함")
        } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wikiDir.path)

        let entries = await store.allEntries()
        let autoEntry = try XCTUnwrap(entries.first { $0.sourceName == "복원 전 자동 백업" })
        XCTAssertNil(autoEntry.resultFile)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: dataDir.appendingPathComponent("wiki-backups").path)
        XCTAssertFalse(backups.contains { $0.contains("-result") })
    }

    /// 7. 새 페이지 되돌리기 — 새 로그 항목 생성 없음(기존 동작 불변, resultFile 도입 후에도 유지).
    func testRestoreNewPageStillCreatesNoNewLogEntry() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("새주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: nil, sourceName: "s.pdf")
        try "# 새 페이지".write(to: page, atomically: true, encoding: .utf8)

        try await store.restore(entry)
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)   // recordApply가 만든 원 항목뿐, 추가 항목 없음.
    }

    /// 8. 유일 파일명 — 같은 페이지에 result를 두 번(연속 호출) 기록해도 파일명이 충돌하지 않는다.
    func testRecordResultUniquifiesSameSecondFilenames() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry1 = try await store.recordApply(pageURL: page, oldBody: "old1", sourceName: "s1")
        let entry2 = try await store.recordApply(pageURL: page, oldBody: "old2", sourceName: "s2")
        try await store.recordResult(entryID: entry1.id, newBody: "new1")
        try await store.recordResult(entryID: entry2.id, newBody: "new2")

        let entries = await store.allEntries()
        let result1 = try XCTUnwrap(entries.first { $0.id == entry1.id }?.resultFile)
        let result2 = try XCTUnwrap(entries.first { $0.id == entry2.id }?.resultFile)
        XCTAssertNotEqual(result1, result2)
        let backupsDir = dataDir.appendingPathComponent("wiki-backups")
        XCTAssertEqual(try String(contentsOf: backupsDir.appendingPathComponent(result1), encoding: .utf8), "new1")
        XCTAssertEqual(try String(contentsOf: backupsDir.appendingPathComponent(result2), encoding: .utf8), "new2")
    }
}
