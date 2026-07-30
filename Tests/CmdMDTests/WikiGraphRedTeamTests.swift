import XCTest
import CoreGraphics
@testable import CmdMD

/// G003 경계 QA / red-team — 실제 디스크 위키 볼트 + 실제 actor I/O 종단간 검증.
/// 기존 테스트/구현을 수정하지 않고 적대적 시나리오만 추가한다.
final class WikiGraphRedTeamTests: XCTestCase {
    var wikiRoot: URL!
    var dataDir: URL!

    override func setUpWithError() throws {
        wikiRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-redteam-\(UUID().uuidString)", isDirectory: true)
        dataDir = TempDataDirectory.make()
        try FileManager.default.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wikiRoot.path)
        try? FileManager.default.removeItem(at: wikiRoot)
        TempDataDirectory.cleanup(dataDir)
        wikiRoot = nil
        dataDir = nil
        super.tearDown()
    }

    // MARK: - 1. 순환 링크 (A→B→C→A)

    /// 심하게 중첩된 순환 위키링크가 있어도 `WikiGraphLoader.load`가 무한루프 없이 종료되고
    /// 순환 그래프(3노드·3엣지)가 정상 생성되는지 실제 디스크 I/O로 검증.
    func testCircularWikiLinksTerminateWithoutHang() async throws {
        try writePage("A.md", "# A\n[[B]]\n")
        try writePage("B.md", "# B\n[[C]]\n")
        try writePage("C.md", "# C\n[[A]]\n")

        let loader = WikiGraphLoader()
        let started = Date()
        let snapshot = await loader.load(root: wikiRoot, size: CGSize(width: 800, height: 600))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5.0, "순환 그래프 로드가 5초 안에 끝나야 함(무한루프 금지)")
        XCTAssertEqual(snapshot.graph.stats.nodeCount, 3)
        XCTAssertEqual(snapshot.graph.stats.unreadablePageCount, 0)
        XCTAssertEqual(snapshot.graph.stats.unresolvedCount, 0)

        let edgeIDs = Set(snapshot.graph.edges.map(\.id))
        XCTAssertEqual(edgeIDs, ["A.md->B.md", "B.md->C.md", "C.md->A.md"])
        XCTAssertEqual(snapshot.positions.count, 3, "레이아웃도 3노드 좌표를 내야 함")
    }

    // MARK: - 2. 손상 인코딩 / 용량 초과

    /// 잘못된 UTF-8 바이트와 1MB 초과 파일을 실제 디스크에 두고, 크래시 없이
    /// `unreadablePageCount`로 정확히 집계되는지 검증.
    func testCorruptEncodingAndOversizedFilesCountedUnreadable() async throws {
        try writePage("ok.md", "# OK\n[[ok]]\n")

        // 잘못된 UTF-8(단독 continuation / overlong 유사 바이트)
        let corruptURL = wikiRoot.appendingPathComponent("corrupt.md")
        try Data([0xFF, 0xFE, 0xFD, 0xC0, 0x80, 0xE0, 0x80, 0x80]).write(to: corruptURL)

        // 1MB 초과(bodySizeLimit = 1_000_000)
        let oversizedURL = wikiRoot.appendingPathComponent("huge.md")
        let huge = Data(repeating: UInt8(ascii: "x"), count: WikiGraphLoader.bodySizeLimit + 2_048)
        try huge.write(to: oversizedURL)

        let loader = WikiGraphLoader()
        let snapshot = await loader.load(root: wikiRoot, size: CGSize(width: 400, height: 300))

        XCTAssertEqual(snapshot.graph.stats.nodeCount, 3, "읽지 못한 파일도 노드는 유지")
        XCTAssertEqual(snapshot.graph.stats.unreadablePageCount, 2,
                       "손상 인코딩 1 + 용량초과 1 = 읽지 못함 2")
        XCTAssertTrue(snapshot.graph.nodes.map(\.id).contains("corrupt.md"))
        XCTAssertTrue(snapshot.graph.nodes.map(\.id).contains("huge.md"))
        XCTAssertTrue(snapshot.graph.nodes.map(\.id).contains("ok.md"))
        XCTAssertEqual(snapshot.graph.stats.unreadablePageCount, 2)
    }

    // MARK: - 3. 동시성 공격 (actor 직렬화)

    /// 여러 Task가 동시에 `recordApply`·`recordResult`를 반복 호출해도
    /// 로그 JSON이 파싱 가능하고, resultFile↔디스크 대응이 고아 없이 일치하는지 검증.
    func testConcurrentRecordApplyAndResultLeavesNoOrphans() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let pageCount = 12
        let pages: [URL] = (0..<pageCount).map { i in
            wikiRoot.appendingPathComponent(String(format: "p%02d.md", i))
        }
        for page in pages {
            try "# seed".write(to: page, atomically: true, encoding: .utf8)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (i, page) in pages.enumerated() {
                    group.addTask {
                        let entry = try await store.recordApply(
                            pageURL: page, oldBody: "old-\(i)", sourceName: "src-\(i).pdf")
                        try await store.recordResult(entryID: entry.id, newBody: "new-\(i)")
                    }
                    // 같은 페이지에 겹치는 apply만 하는 경쟁 태스크도 섞는다.
                    if i % 3 == 0 {
                        group.addTask {
                            _ = try await store.recordApply(
                                pageURL: page, oldBody: "race-old-\(i)", sourceName: "race-\(i)")
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            XCTFail("동시 recordApply/recordResult가 예외를 던짐: \(error)")
        }

        let entries = await store.allEntries()
        XCTAssertFalse(entries.isEmpty)

        // 로그 파일이 손상되지 않았는지 — 새 인스턴스로 재로드
        let reloaded = WikiBackupStore(directory: dataDir)
        let persisted = await reloaded.allEntries()
        XCTAssertEqual(persisted.count, entries.count)
        XCTAssertEqual(Set(persisted.map(\.id)), Set(entries.map(\.id)))

        let backupsDir = dataDir.appendingPathComponent("wiki-backups")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        let resultFilesOnDisk = Set(onDisk.filter { $0.contains("-result") })
        let resultFilesInLog = Set(entries.compactMap(\.resultFile))

        // 로그에 있는 resultFile은 전부 디스크에 존재
        for name in resultFilesInLog {
            XCTAssertTrue(resultFilesOnDisk.contains(name), "로그 resultFile 누락: \(name)")
            let body = try String(contentsOf: backupsDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(body.isEmpty)
        }
        // 디스크의 result 파일은 전부 로그에 참조됨(고아 0)
        XCTAssertEqual(resultFilesOnDisk, resultFilesInLog,
                       "고아 result 파일 또는 로그-디스크 불일치")

        // 백업 파일도 로그와 대응
        let backupFilesInLog = Set(entries.compactMap(\.backupFile))
        for name in backupFilesInLog {
            XCTAssertTrue(onDisk.contains(name), "로그 backupFile 누락: \(name)")
        }
    }

    // MARK: - 4. 경로 해석 경계 (하위폴더 / ../ / 대소문자)

    /// 실제 하위 폴더·`../` 상대경로·대소문자 섞인 파일명을 디스크에 만들고
    /// `WikiGraphLoader` 해석이 실제 APFS(case-insensitive) 관례와 일치하는지 검증.
    func testPathResolutionSubfolderParentAndCaseInsensitive() async throws {
        let folder = wikiRoot.appendingPathComponent("folder", isDirectory: true)
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try writePage("RootNote.md", "# root\n")
        try "# a\n[상위](../RootNote.md) [하위](sub/Child.md) [[MixedCase]]\n"
            .write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# child\n".write(to: sub.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        // 디스크에는 MixedCase.md — 링크는 mixedcase / MIXEDCASE 혼용
        try writePage("MixedCase.md", "# mixed\n[자기대소문자](mixedcase.md)\n")

        let loader = WikiGraphLoader()
        let snapshot = await loader.load(root: wikiRoot, size: CGSize(width: 640, height: 480))
        let edgeIDs = Set(snapshot.graph.edges.map(\.id))

        XCTAssertEqual(snapshot.graph.stats.unreadablePageCount, 0)
        XCTAssertGreaterThanOrEqual(snapshot.graph.stats.nodeCount, 4)

        // markdown 상대경로: folder/a.md → ../RootNote.md, folder/a.md → sub/Child.md
        XCTAssertTrue(edgeIDs.contains("folder/a.md->RootNote.md"),
                      "../ 상위 해석 실패. edges=\(edgeIDs)")
        XCTAssertTrue(edgeIDs.contains("folder/a.md->folder/sub/Child.md"),
                      "하위 폴더 해석 실패. edges=\(edgeIDs)")

        // 위키링크 stem 대소문자 무시 + markdown 경로 대소문자 무시
        XCTAssertTrue(edgeIDs.contains("folder/a.md->MixedCase.md"),
                      "위키링크 대소문자 무시 해석 실패. edges=\(edgeIDs)")
        // MixedCase.md 본문의 [자기대소문자](mixedcase.md) — 자기참조면 엣지 제거가 정상
        XCTAssertFalse(edgeIDs.contains("MixedCase.md->MixedCase.md"),
                       "자기참조 엣지는 제거되어야 함")

        XCTAssertEqual(snapshot.graph.stats.unresolvedCount, 0,
                       "존재하는 파일로의 링크가 unresolved로 떨어지면 안 됨: \(snapshot.graph.unresolvedLinks)")
    }

    // MARK: - 5. 복원 실패 조합 (읽기전용 + 동시 복원 2+)

    /// 대상 폴더 읽기전용 + 서로 다른 페이지 복원 2건을 동시에 실행했을 때,
    /// "복원 전 자동 백업"이 legacy(resultFile==nil)로 남고 고아 result 파일이 0개인지
    /// 실제 디렉터리 스캔으로 검증. WikiHistoryGrouping도 함께 확인.
    func testConcurrentRestoreFailuresLeaveLegacyAutoBackupsNoOrphanResults() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let pageA = wikiRoot.appendingPathComponent("topicA.md")
        let pageB = wikiRoot.appendingPathComponent("topicB.md")
        try "A-old".write(to: pageA, atomically: true, encoding: .utf8)
        try "B-old".write(to: pageB, atomically: true, encoding: .utf8)

        let entryA = try await store.recordApply(pageURL: pageA, oldBody: "A-old", sourceName: "a.pdf")
        try await store.recordResult(entryID: entryA.id, newBody: "A-new")
        try "A-new".write(to: pageA, atomically: true, encoding: .utf8)

        let entryB = try await store.recordApply(pageURL: pageB, oldBody: "B-old", sourceName: "b.pdf")
        try await store.recordResult(entryID: entryB.id, newBody: "B-new")
        try "B-new".write(to: pageB, atomically: true, encoding: .utf8)

        // 성공 경로에서 이미 생긴 result 파일 수를 기록(이후 증가하면 안 됨)
        let backupsDir = dataDir.appendingPathComponent("wiki-backups")
        let beforeResults = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
            .filter { $0.contains("-result") }
        XCTAssertEqual(beforeResults.count, 2)

        // 읽기전용으로 만들어 복원 파일 쓰기 실패 주입
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: wikiRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wikiRoot.path)
        }

        var failures = 0
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await store.restore(entryA)
                    return false
                } catch {
                    return true
                }
            }
            group.addTask {
                do {
                    try await store.restore(entryB)
                    return false
                } catch {
                    return true
                }
            }
            for await failed in group {
                if failed { failures += 1 }
            }
        }
        XCTAssertEqual(failures, 2, "동시 복원 2건 모두 쓰기 실패여야 함")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wikiRoot.path)

        let entries = await store.allEntries()
        let autoEntries = entries.filter { $0.sourceName == "복원 전 자동 백업" }
        XCTAssertEqual(autoEntries.count, 2, "실패 복원마다 자동 백업 항목 1개")
        for auto in autoEntries {
            XCTAssertNil(auto.resultFile, "쓰기 실패 시 자동 백업은 legacy(resultFile==nil)")
            XCTAssertNotNil(auto.backupFile)
        }

        let afterDisk = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        let afterResults = afterDisk.filter { $0.contains("-result") }
        XCTAssertEqual(afterResults.count, beforeResults.count,
                       "복원 실패 경로에서 새 result 파일이 생기면 안 됨")

        // 로그에 없는 고아 result 파일 0
        let loggedResults = Set(entries.compactMap(\.resultFile))
        XCTAssertEqual(Set(afterResults), loggedResults)

        // HistoryGrouping이 legacy로 분류하는지(본문 스냅샷 주입)
        let bodies = await store.snapshotBodies(for: entries)
        let rows = WikiHistoryGrouping.rows(entries: entries, bodies: bodies, pageFilter: nil)
        let autoRows = rows.filter(\.isRestoreEvent)
        XCTAssertEqual(autoRows.count, 2)
        for row in autoRows {
            if case .legacyNoResult = row.diffState {
                // ok
            } else {
                XCTFail("복원 실패 자동 백업은 legacyNoResult여야 함: \(row.diffState)")
            }
        }
    }

    // MARK: - helpers

    private func writePage(_ relative: String, _ body: String) throws {
        let url = wikiRoot.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent()
        if parent.path != wikiRoot.path {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
