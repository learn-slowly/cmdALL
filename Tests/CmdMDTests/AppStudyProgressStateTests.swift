import XCTest
@testable import CmdMD

/// 교재 진도 관리 배선(`AppState+StudyProgress.swift`) — 등록·읽음 체크·장 추가·목차 다시
/// 읽기가 임시 폴더 격리 상태에서 실제 파일과 함께 동작하는지 본다. 순수 계산·파일 형식은
/// 각자 전용 테스트가 검증하므로 여기선 "이어 붙임"과 파일 IO만 확인한다.
@MainActor
final class AppStudyProgressStateTests: XCTestCase {
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

    // MARK: - 도우미

    private func studyFolder() -> URL {
        let folder = app.effectiveStudyFolders().first!
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 헤딩이 있는 마크다운 교재 하나(마크다운은 kordoc·PDFKit 없이 목차를 뽑을 수 있다).
    @discardableResult
    private func makeMarkdownTextbook(name: String = "교재.md") -> URL {
        let url = studyFolder().appendingPathComponent(name)
        let content = """
        머리말입니다.
        # 1장
        내용
        내용
        # 2장
        내용
        내용
        내용
        """
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func registerTextbook(_ url: URL) async {
        await app.prepareStudyProgressOutline(for: url)
        await app.confirmStudyProgressBook()
    }

    // MARK: - 등록 흐름(제안 → 확인 → 실행)

    func testPreparingOutlineCreatesNoFile() async {
        let url = makeMarkdownTextbook()
        await app.prepareStudyProgressOutline(for: url)

        XCTAssertNotNil(app.studyProgressPendingOutline)
        XCTAssertEqual(app.studyProgressPendingOutline?.chapters.count, 3)
        let folder = app.studyProgressFolder()!
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "미리보기 단계에선 진도 폴더조차 만들지 않는다")
    }

    func testConfirmWritesProgressNoteAndLoadsBook() async {
        let url = makeMarkdownTextbook()
        await registerTextbook(url)

        XCTAssertEqual(app.studyProgressBooks.count, 1)
        let book = app.studyProgressBooks[0]
        XCTAssertEqual(book.title, "교재.md")
        XCTAssertTrue(book.sourceExists)
        XCTAssertEqual(book.summary.chapters.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.noteURL.path))
        XCTAssertNil(app.studyProgressPendingOutline, "등록 후 미리보기 상태는 비워진다")
    }

    func testRegisteringSameTextbookTwiceIsRejected() async {
        let url = makeMarkdownTextbook()
        await registerTextbook(url)
        await app.prepareStudyProgressOutline(for: url)

        XCTAssertEqual(app.studyProgressError, "이미 등록된 교재입니다.")
        XCTAssertNil(app.studyProgressPendingOutline)
    }

    func testUnsupportedKindIsRejected() async {
        let url = studyFolder().appendingPathComponent("사진.png")
        try? Data([0x89]).write(to: url)
        await app.prepareStudyProgressOutline(for: url)

        XCTAssertEqual(app.studyProgressError, "이 형식은 진도 관리를 지원하지 않습니다.")
        XCTAssertNil(app.studyProgressPendingOutline)
    }

    // MARK: - 읽음 체크

    func testTogglingReadUpdatesRatioAndKeepsBackup() async {
        await registerTextbook(makeMarkdownTextbook())
        let book = app.studyProgressBooks[0]
        let total = book.summary.total
        let firstChapterLength = book.summary.chapters[0].chapter.length

        await app.toggleStudyProgressRead(bookID: book.id, chapterNo: 1, read: true)

        let updated = app.studyProgressBooks[0]
        XCTAssertEqual(updated.summary.readLength, firstChapterLength)
        XCTAssertEqual(updated.summary.readRatio, Double(firstChapterLength) / Double(total), accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.noteURL.path + ".bak"),
                      "덮어쓰기 전 백업 1부를 남긴다(채점 쓰기와 같은 어법)")
    }

    func testUncheckingRestoresZero() async {
        await registerTextbook(makeMarkdownTextbook())
        let bookID = app.studyProgressBooks[0].id

        await app.toggleStudyProgressRead(bookID: bookID, chapterNo: 1, read: true)
        await app.toggleStudyProgressRead(bookID: bookID, chapterNo: 1, read: false)

        XCTAssertEqual(app.studyProgressBooks[0].summary.readLength, 0)
    }

    // MARK: - 장 직접 추가

    func testAddingChapterSplitsRange() async {
        await registerTextbook(makeMarkdownTextbook())
        let book = app.studyProgressBooks[0]

        await app.addStudyProgressChapter(bookID: book.id, title: "새 장", start: 3)

        let chapters = app.studyProgressBooks[0].summary.chapters.map(\.chapter)
        XCTAssertTrue(chapters.contains { $0.title == "새 장" && $0.start == 3 })
        XCTAssertEqual(chapters.map(\.no), Array(1...chapters.count), "번호는 다시 1부터 이어진다")
    }

    func testAddingChapterOutsideRangeIsRejected() async {
        await registerTextbook(makeMarkdownTextbook())
        let book = app.studyProgressBooks[0]
        let before = book.summary.chapters.count

        await app.addStudyProgressChapter(bookID: book.id, title: "범위 밖", start: 9_999)

        XCTAssertEqual(app.studyProgressBooks[0].summary.chapters.count, before)
        XCTAssertNotNil(app.studyProgressError)
    }

    func testAddingChapterWithEmptyTitleIsRejected() async {
        await registerTextbook(makeMarkdownTextbook())
        let book = app.studyProgressBooks[0]

        await app.addStudyProgressChapter(bookID: book.id, title: "   ", start: 2)

        XCTAssertEqual(app.studyProgressError, "장 이름을 적어 주세요.")
    }

    // MARK: - 목차 다시 읽기

    func testRefreshingOutlineKeepsReadMarks() async {
        let url = makeMarkdownTextbook()
        await registerTextbook(url)
        let bookID = app.studyProgressBooks[0].id
        await app.toggleStudyProgressRead(bookID: bookID, chapterNo: 2, read: true)

        // 교재에 내용을 덧붙이고 목차를 다시 읽는다.
        let extended = """
        머리말입니다.
        # 1장
        내용
        내용
        # 2장
        내용
        내용
        내용
        더 붙인 줄
        """
        try? extended.write(to: url, atomically: true, encoding: .utf8)
        await app.refreshStudyProgressOutline(bookID: bookID)

        let book = app.studyProgressBooks[0]
        XCTAssertEqual(book.summary.total, 9, "총 분량이 새 줄 수로 갱신된다")
        XCTAssertTrue(book.summary.chapters[1].chapter.read, "이미 읽은 표시는 잃지 않는다")
    }

    // MARK: - 카드·문제 연결(진도 '만듦'·'익힘')

    func testMadeRatioReflectsCardsCreatedFromThatTextbook() async {
        let folder = studyFolder()
        let url = makeMarkdownTextbook()
        await registerTextbook(url)

        // 교재의 5번째 줄(= 2장)에서 만든 카드 노트 하나.
        let scope = StudyScope(fileURL: url, kind: .markdown, range: .wholeFile)
        let cards = [StudyCard(title: "카드", bullets: ["불릿"], locator: .line(5),
                               quote: "발췌", unverifiedQuote: false)]
        let note = StudyNoteWriter.buildCardNote(cards: cards, scope: scope, noteFolder: folder, title: "카드")
        try? note.body.write(to: folder.appendingPathComponent("카드.md"), atomically: true, encoding: .utf8)

        await app.rebuildStudyIndex()
        await app.loadStudyProgress()

        let book = app.studyProgressBooks[0]
        XCTAssertEqual(book.summary.itemCount, 1, "그 교재에서 만든 항목이 잡힌다")
        XCTAssertGreaterThan(book.summary.madeRatio, 0)
        XCTAssertEqual(book.summary.masteredRatio, 0, "새 항목은 아직 익힘이 아니다")
    }

    func testSuggestionsListTextbooksWithCardsButNotRegistered() async {
        let folder = studyFolder()
        let url = makeMarkdownTextbook(name: "미등록교재.md")
        let scope = StudyScope(fileURL: url, kind: .markdown, range: .wholeFile)
        let cards = [StudyCard(title: "카드", bullets: ["불릿"], locator: .line(2),
                               quote: "발췌", unverifiedQuote: false)]
        let note = StudyNoteWriter.buildCardNote(cards: cards, scope: scope, noteFolder: folder, title: "카드")
        try? note.body.write(to: folder.appendingPathComponent("카드.md"), atomically: true, encoding: .utf8)

        await app.rebuildStudyIndex()
        await app.loadStudyProgress()

        XCTAssertEqual(app.studyProgressSuggestions.map(\.lastPathComponent), ["미등록교재.md"])

        await registerTextbook(url)
        XCTAssertTrue(app.studyProgressSuggestions.isEmpty, "등록하면 제안 목록에서 빠진다")
    }

    // MARK: - 모드 전환

    func testOpenStudyProgressSwitchesMode() {
        app.openStudyProgressView()
        XCTAssertEqual(app.mainMode, .progress)
    }

    func testProgressNotesAreNotCountedAsReviewItems() async {
        await registerTextbook(makeMarkdownTextbook())
        await app.rebuildStudyIndex()

        XCTAssertEqual(app.studyDueCount, 0, "진도 노트는 복습 대상이 아니다")
    }
}
