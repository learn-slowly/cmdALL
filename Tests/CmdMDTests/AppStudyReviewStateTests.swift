import XCTest
@testable import CmdMD

/// 학습도우미 복습(S2) — `AppState+StudyReview.swift` 배선(폴더 계산·재빌드·오늘 복습 화면·
/// 채점 쓰기)이 임시 디렉터리 격리 상태에서 정확히 동작하는지 확인한다. 순수 계산(`ReviewScheduler`)·
/// 파싱(`StudyNoteParser`)·캐시(`StudyIndex`)는 각자 전용 테스트가 이미 검증했으므로 여기선
/// "이어 붙임"과 실제 파일 IO(백업·재확인)만 본다.
@MainActor
final class AppStudyReviewStateTests: XCTestCase {
    var tempData: URL!
    var vaultRoot: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        vaultRoot = tempData.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        app = AppState(dataDirectory: tempData)
        app.vaults = [Vault(name: "테스트볼트", rootPath: vaultRoot)]
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        super.tearDown()
    }

    // MARK: - 폴더 계산(§3.7 기본값)

    func testEffectiveStudyFoldersDefaultsToSendFolder() {
        let folders = app.effectiveStudyFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.path,
                        vaultRoot.appendingPathComponent(app.effectiveSendFolder(for: app.defaultVault!)).path)
    }

    func testEffectiveStudyFoldersUsesConfiguredListWhenNotEmpty() {
        let custom = tempData.appendingPathComponent("따로", isDirectory: true)
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        app.settings.studyFolders = [custom.path]
        let folders = app.effectiveStudyFolders()
        XCTAssertEqual(folders.map(\.path), [custom.path])
    }

    func testEffectiveStudyFoldersEmptyWhenNoVaultAndNoConfig() {
        app.vaults = []
        XCTAssertTrue(app.effectiveStudyFolders().isEmpty)
    }

    // MARK: - 헬퍼

    private func effectiveFolder() -> URL {
        app.effectiveStudyFolders().first!
    }

    private func sequentialUUIDGenerator(seed: Int = 0) -> () -> UUID {
        var counter = seed
        return {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        }
    }

    @discardableResult
    private func writeDueCardNote(name: String = "카드.md", title: String = "제목") -> URL {
        let folder = effectiveFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scope = StudyScope(fileURL: folder.appendingPathComponent("교재.pdf"), kind: .pdf, range: .wholeFile)
        let cards = [StudyCard(title: title, bullets: ["불릿"], locator: .page(1), quote: "발췌", unverifiedQuote: false)]
        // due를 오늘로 만들기 위해 now를 오늘로 준다(StudyReviewState.initial(now:) 규칙).
        let result = StudyNoteWriter.buildCardNote(cards: cards, scope: scope, noteFolder: folder, title: title,
                                                     makeUUID: sequentialUUIDGenerator())
        let url = folder.appendingPathComponent(name)
        try? result.body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 재빌드

    func testRebuildStudyIndexUpdatesDueCountAndNotice() async {
        writeDueCardNote()
        await app.rebuildStudyIndex()
        XCTAssertEqual(app.studyDueCount, 1)
        XCTAssertNotNil(app.studyReviewRebuildNotice)
        XCTAssertTrue(app.studyReviewRebuildNotice!.contains("1건"))
    }

    func testRebuildStudyIndexSkipsSilentlyWhenNoFolder() async {
        app.vaults = []
        await app.rebuildStudyIndex()
        XCTAssertEqual(app.studyDueCount, 0)
        XCTAssertNil(app.studyReviewRebuildNotice)
    }

    // MARK: - 오늘 복습 화면

    func testOpenStudyReviewLoadsQueue() async {
        writeDueCardNote()
        await app.rebuildStudyIndex()
        await app.openStudyReview()
        XCTAssertTrue(app.showStudyReview)
        XCTAssertEqual(app.studyReviewQueue.count, 1)
        XCTAssertEqual(app.studyReviewIndex, 0)
        XCTAssertNotNil(app.currentStudyReviewItem)
    }

    func testCloseStudyReviewClearsState() async {
        writeDueCardNote()
        await app.rebuildStudyIndex()
        await app.openStudyReview()
        app.closeStudyReview()
        XCTAssertFalse(app.showStudyReview)
        XCTAssertTrue(app.studyReviewQueue.isEmpty)
    }

    // MARK: - 채점 쓰기(§3.6) — 실제 파일 IO

    func testGradeCurrentStudyReviewItemWritesBackupAndAdvances() async {
        let url = writeDueCardNote(title: "채점 대상")
        await app.rebuildStudyIndex()
        await app.openStudyReview()
        XCTAssertEqual(app.studyReviewQueue.count, 1)
        let originalContent = try! String(contentsOf: url, encoding: .utf8)

        await app.gradeCurrentStudyReviewItem(.knew)

        XCTAssertNil(app.studyReviewError)
        XCTAssertEqual(app.studyReviewIndex, 1, "채점 성공 시 다음 항목으로 넘어간다")
        XCTAssertEqual(app.studyDueCount, 0)

        let backupURL = URL(fileURLWithPath: url.path + ".bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backupContent = try! String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertEqual(backupContent, originalContent, "백업은 덮어쓰기 직전 원본과 같아야 한다")

        let newContent = try! String(contentsOf: url, encoding: .utf8)
        XCTAssertNotEqual(newContent, originalContent, "앵커 줄이 새 상태로 바뀌어야 한다")
        XCTAssertTrue(newContent.contains("ivl=1"), "\"앎\" 첫 성공은 간격 1일이어야 한다(§3.9)")
        XCTAssertTrue(newContent.contains("reps=1"))
        XCTAssertTrue(newContent.contains("### [카드] 채점 대상"), "제목·본문은 그대로여야 한다")
    }

    func testGradeCurrentStudyReviewItemAbortsWhenNoteChangedExternally() async {
        let url = writeDueCardNote(title: "충돌 대상")
        await app.rebuildStudyIndex()
        await app.openStudyReview()
        let originalContent = try! String(contentsOf: url, encoding: .utf8)

        // 큐를 불러온 뒤, 화면이 모르는 사이 앵커 줄 자체가 바뀐 상황을 재현(§3.6 "채점 직전
        // 외부 변경") — 다른 줄이 아니라 그 항목의 앵커 줄을 직접 고쳐야 재확인이 진짜로 걸린다.
        let tamperedContent = originalContent.replacingOccurrences(of: "ivl=0", with: "ivl=9")
        XCTAssertNotEqual(tamperedContent, originalContent, "치환이 실제로 일어났는지 먼저 확인")
        try! tamperedContent.write(to: url, atomically: true, encoding: .utf8)

        await app.gradeCurrentStudyReviewItem(.knew)

        XCTAssertNotNil(app.studyReviewError, "재확인 실패 시 안내가 떠야 한다")
        XCTAssertEqual(app.studyReviewIndex, 0, "쓰기를 포기했으니 다음 항목으로 넘어가면 안 된다")
        let backupURL = URL(fileURLWithPath: url.path + ".bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path), "쓰기를 포기했으니 백업도 생기면 안 된다")
    }

    func testGradeCurrentStudyReviewItemNoOpWhenQueueEmpty() async {
        await app.gradeCurrentStudyReviewItem(.knew)
        XCTAssertNil(app.studyReviewError)
    }

    // MARK: - 노트 열기

    func testOpenCurrentStudyReviewNoteSwitchesToReader() async {
        writeDueCardNote()
        await app.rebuildStudyIndex()
        await app.openStudyReview()
        app.mainMode = .library
        app.openCurrentStudyReviewNote()
        XCTAssertEqual(app.mainMode, .reader)
    }

    // MARK: - 설정 폴더 등록/해제

    func testRegisterStudyFolderAppendsPathOnce() {
        let custom = tempData.appendingPathComponent("손으로등록", isDirectory: true)
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        app.registerStudyFolder(custom)
        app.registerStudyFolder(custom)   // 두 번 등록해도 한 번만 남는다.
        XCTAssertEqual(app.settings.studyFolders, [custom.standardizedFileURL.path])
    }

    func testUnregisterStudyFolderRemovesPath() {
        let custom = tempData.appendingPathComponent("손으로등록", isDirectory: true)
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        app.registerStudyFolder(custom)
        app.unregisterStudyFolder(custom.standardizedFileURL.path)
        XCTAssertTrue(app.settings.studyFolders.isEmpty)
    }
}
