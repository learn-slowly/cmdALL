import XCTest
@testable import CmdMD

/// 학습도우미 복습(S2) — `StudyIndex`(캐시 actor)가 §3.6(중복·손상 정책)·§3.7(재빌드 범위)·
/// §3.9(하루 상한)를 정확히 지키는지 실제 임시 디렉터리·실제 파일로 확인한다.
final class StudyIndexTests: XCTestCase {
    var tempDir: URL!
    var studyFolder: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
        studyFolder = tempDir.appendingPathComponent("study", isDirectory: true)
        try? FileManager.default.createDirectory(at: studyFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        super.tearDown()
    }

    private func dbURL() -> URL { tempDir.appendingPathComponent("studyindex-\(UUID().uuidString).sqlite") }

    private func sequentialUUIDGenerator(seed: Int = 1) -> () -> UUID {
        var counter = seed
        return {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        }
    }

    @discardableResult
    private func writeCardNote(
        name: String, title: String = "제목", mtime: Date? = nil, seed: Int = 1
    ) throws -> URL {
        let scope = StudyScope(fileURL: studyFolder.appendingPathComponent("교재.pdf"), kind: .pdf, range: .wholeFile)
        let cards = [StudyCard(title: title, bullets: ["불릿"], locator: .page(1),
                                quote: "발췌", unverifiedQuote: false)]
        let result = StudyNoteWriter.buildCardNote(
            cards: cards, scope: scope, noteFolder: studyFolder, title: title,
            now: Date(timeIntervalSince1970: 1_750_000_000), makeUUID: sequentialUUIDGenerator(seed: seed))
        let url = studyFolder.appendingPathComponent(name)
        try result.body.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// 같은 `item_uid`를 강제로 지정한 카드 노트(중복 승자 테스트 전용) — `StudyNoteWriter`는
    /// 매번 새 uuid를 발급하므로, 여기선 앵커 줄을 직접 조립한다.
    @discardableResult
    private func writeCardNoteWithFixedUID(name: String, uid: UUID, title: String, mtime: Date) throws -> URL {
        let content = """
        ---
        study_id: \(UUID().uuidString)
        study_kind: card
        study_source: "../교재.pdf"
        study_source_kind: pdf
        study_created: 2026-08-01T00:00:00Z
        study_items: 1
        study_due: 2026-08-01
        ---

        <!-- study item=\(uid.uuidString) src=../교재.pdf loc=p1 due=2026-08-01 ivl=0 ease=2.50 reps=0 lapses=0 -->
        ### [카드] \(title)
        - 불릿
        > 근거: [[p1]] "발췌"
        """
        let url = studyFolder.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func writeChatNote(name: String) throws -> URL {
        var session = StudyChatSession(sourceURL: nil, pinnedExcerpt: "")
        session.turns = [StudyChatTurn(role: .user, text: "질문")]
        let result = StudyNoteWriter.buildChatNote(
            session: session, sourceKind: nil, noteFolder: studyFolder, title: "대화",
            now: Date(timeIntervalSince1970: 1_750_000_000))
        let url = studyFolder.appendingPathComponent(name)
        try result.body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 재빌드 기본

    func testRebuildFindsCardItems() async throws {
        try writeCardNote(name: "카드1.md", title: "첫 카드")
        let index = StudyIndex(dbURL: dbURL())
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 1)
        XCTAssertEqual(summary.excluded, 0)
        let count = await index.count()
        XCTAssertEqual(count, 1)
    }

    func testRebuildExcludesFileWithoutStudyID() async throws {
        try "# 그냥 메모\n아무 내용".write(
            to: studyFolder.appendingPathComponent("그냥.md"), atomically: true, encoding: .utf8)
        let index = StudyIndex(dbURL: dbURL())
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 0)
    }

    func testRebuildExcludesChatNotes() async throws {
        _ = try writeChatNote(name: "대화.md")
        let index = StudyIndex(dbURL: dbURL())
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 0, "대화 노트는 복습 대상이 아니다")
    }

    // AC #28 "등록 폴더 밖 노트는 인덱스 미포함"
    func testRebuildExcludesFoldersOutsideRegisteredList() async throws {
        let otherFolder = tempDir.appendingPathComponent("밖", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let scope = StudyScope(fileURL: otherFolder.appendingPathComponent("교재.pdf"), kind: .pdf, range: .wholeFile)
        let cards = [StudyCard(title: "제목", bullets: ["불릿"], locator: .page(1), quote: "발췌", unverifiedQuote: false)]
        let result = StudyNoteWriter.buildCardNote(cards: cards, scope: scope, noteFolder: otherFolder, title: "제목",
                                                     makeUUID: sequentialUUIDGenerator())
        try result.body.write(to: otherFolder.appendingPathComponent("카드.md"), atomically: true, encoding: .utf8)

        let index = StudyIndex(dbURL: dbURL())
        let summary = await index.rebuild(folders: [studyFolder])   // otherFolder는 등록 안 함
        XCTAssertEqual(summary.included, 0)
    }

    // MARK: - §3.6 uid 중복 승자 규칙

    func testDuplicateUIDResolvesToNewerMtimeWinner() async throws {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        try writeCardNoteWithFixedUID(name: "옛것.md", uid: uid, title: "옛 버전",
                                       mtime: Date(timeIntervalSince1970: 1_000))
        try writeCardNoteWithFixedUID(name: "새것.md", uid: uid, title: "새 버전",
                                       mtime: Date(timeIntervalSince1970: 2_000))
        let index = StudyIndex(dbURL: dbURL())
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 1)
        XCTAssertEqual(summary.excluded, 1)
        let due = await index.dueItems(today: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(due.first?.title, "새 버전")
    }

    func testDuplicateUIDSameMtimeResolvesToAlphabeticallyFirstPath() async throws {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let sameMtime = Date(timeIntervalSince1970: 5_000)
        try writeCardNoteWithFixedUID(name: "b-노트.md", uid: uid, title: "B", mtime: sameMtime)
        try writeCardNoteWithFixedUID(name: "a-노트.md", uid: uid, title: "A", mtime: sameMtime)
        let index = StudyIndex(dbURL: dbURL())
        _ = await index.rebuild(folders: [studyFolder])
        let due = await index.dueItems(today: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(due.first?.title, "A", "동일 mtime이면 정규화 경로 오름차순(POSIX) 승자")
    }

    // AC #12 "노트를 옮겨도 재빌드 후 item_uid 기준으로 살아 있다"
    func testItemSurvivesNoteMoveAcrossRebuild() async throws {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        let original = try writeCardNoteWithFixedUID(name: "원위치.md", uid: uid, title: "이동 전",
                                                       mtime: Date(timeIntervalSince1970: 3_000))
        let index = StudyIndex(dbURL: dbURL())
        _ = await index.rebuild(folders: [studyFolder])
        let countAfterFirst = await index.count()
        XCTAssertEqual(countAfterFirst, 1)

        let moved = studyFolder.appendingPathComponent("새위치.md")
        try FileManager.default.moveItem(at: original, to: moved)
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 1)
        let due = await index.dueItems(today: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(due.first?.uid, uid)
        XCTAssertEqual(due.first?.notePath, moved.path)
    }

    // MARK: - AC #14 오늘 복습 = due ≤ 오늘(상한 적용 후)

    func testDueItemsExcludesFutureDueItems() async throws {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        try writeCardNoteWithFixedUID(name: "미래.md", uid: uid, title: "미래 항목",
                                       mtime: Date(timeIntervalSince1970: 1_000))
        // 앵커의 due는 2026-08-01(고정) — "오늘"을 그보다 훨씬 과거로 주면 due ≤ 오늘 조건에서 빠져야 한다.
        let index = StudyIndex(dbURL: dbURL())
        _ = await index.rebuild(folders: [studyFolder])
        let due = await index.dueItems(today: Date(timeIntervalSince1970: 0))   // 1970년 — 2026-08-01보다 훨씬 과거
        XCTAssertTrue(due.isEmpty)
    }

    func testDueItemsAppliesSeparateNewAndReviewCaps() async throws {
        // "새 항목" 3개(reps==0 && lapses==0, 손대지 않음) + 별도 "복습 항목" 3개(채점 갱신을
        // 흉내내 reps>0으로 만듦) 섞어 넣고 newLimit=1·reviewLimit=1로 부르면 정확히 2개
        // (각 종류 1개씩)만 나와야 한다.
        for i in 0..<3 {
            try writeCardNoteWithFixedUID(
                name: "새\(i).md", uid: UUID(uuidString: String(format: "00000000-0000-0000-0000-1000000000%02d", i))!,
                title: "새\(i)", mtime: Date(timeIntervalSince1970: Double(i)))
        }
        for i in 0..<3 {
            try writeCardNoteWithFixedUID(
                name: "복습\(i).md", uid: UUID(uuidString: String(format: "00000000-0000-0000-0000-2000000000%02d", i))!,
                title: "복습\(i)", mtime: Date(timeIntervalSince1970: Double(i)))
        }
        let index = StudyIndex(dbURL: dbURL())
        _ = await index.rebuild(folders: [studyFolder])

        // "복습" 3개만 채점 갱신을 흉내내(캐시 직접 갱신) reps>0으로 만든다 — "새" 3개는 그대로 둔다.
        let reviewedState = StudyReviewState(due: Date(timeIntervalSince1970: 1_722_000_000), interval: 3,
                                              ease: 2.55, reps: 2, lapses: 0)
        for i in 0..<3 {
            let uid = UUID(uuidString: String(format: "00000000-0000-0000-0000-2000000000%02d", i))!
            await index.updateAfterGrading(itemUID: uid, newState: reviewedState, newLineText: "무관")
        }

        let due = await index.dueItems(today: Date(timeIntervalSince1970: 2_000_000_000),
                                        newLimit: 1, reviewLimit: 1)
        XCTAssertEqual(due.count, 2)
    }

    // MARK: - 채점 갱신 캐시 반영

    func testUpdateAfterGradingChangesCachedDueDate() async throws {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
        try writeCardNoteWithFixedUID(name: "갱신.md", uid: uid, title: "갱신 대상",
                                       mtime: Date(timeIntervalSince1970: 1_000))
        let index = StudyIndex(dbURL: dbURL())
        _ = await index.rebuild(folders: [studyFolder])

        let farFuture = Date(timeIntervalSince1970: 4_000_000_000)
        await index.updateAfterGrading(itemUID: uid, newState: StudyReviewState(
            due: farFuture, interval: 180, ease: 2.80, reps: 5, lapses: 0), newLineText: "갱신됨")

        let due = await index.dueItems(today: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertTrue(due.isEmpty, "채점으로 미래로 미뤄진 항목은 더 이상 오늘 목록에 없어야 한다")
    }

    // MARK: - 손상 DB 자가 복구(AC #13)

    func testCorruptedDatabaseSelfHeals() async throws {
        let url = dbURL()
        try "이건 sqlite 파일이 아니다".write(to: url, atomically: true, encoding: .utf8)
        let index = StudyIndex(dbURL: url)
        let count = await index.count()
        XCTAssertEqual(count, 0, "손상 DB는 크래시 없이 빈 상태로 복구돼야 한다")

        try writeCardNote(name: "카드.md")
        let summary = await index.rebuild(folders: [studyFolder])
        XCTAssertEqual(summary.included, 1, "복구 후에도 정상적으로 재빌드된다")
    }
}
