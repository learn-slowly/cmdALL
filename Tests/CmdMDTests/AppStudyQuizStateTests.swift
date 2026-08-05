import XCTest
@testable import CmdMD

/// 문제 풀기(Q3) — `AppState+StudyQuiz.swift` 배선. 형식 읽기(`QuizImportParser`)와 기록장
/// 형식(`QuizRecordNote`)은 각자 전용 테스트가 이미 봤으므로 여기선 "이어 붙임"과 실제 파일 IO만 본다.
@MainActor
final class AppStudyQuizStateTests: XCTestCase {
    var tempData: URL!
    var vaultRoot: URL!
    var quizFolder: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        vaultRoot = tempData.appendingPathComponent("vault", isDirectory: true)
        quizFolder = tempData.appendingPathComponent("100제", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: quizFolder, withIntermediateDirectories: true)
        app = AppState(dataDirectory: tempData)
        app.vaults = [Vault(name: "테스트볼트", rootPath: vaultRoot)]
        app.settings.quizFolders = [quizFolder.path]
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        super.tearDown()
    }

    // MARK: - 표본 문제집

    /// 3문항짜리 문제집 하나를 만든다(정답 ②·①·③).
    @discardableResult
    private func writeQuizBook(named name: String = "문제집_1.1.1_100문항.md") -> URL {
        let md = """
        # 문제집 1.1.1 표본 · 100문항

        ## A. 옳은 것 고르기 (1~2)

        **1.** 첫째 발문
        ① 가
        ② 나

        **2.** 둘째 발문
        ① 다
        ② 라

        ## B. 옳지 않은 것 고르기 (3~3)

        **3.** 셋째 발문
        ① 마
        ② 바
        ③ 사

        # 정답 · 해설

        **1. ②** 첫째 해설. [[교재.pdf#page=9|📖 p.009]]
        **2. ①** 둘째 해설.
        **3. ③** 셋째 해설. [[교재.pdf#page=12|📖 p.012]]
        """
        let url = quizFolder.appendingPathComponent(name)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func recordURL(for source: URL) -> URL {
        app.quizRecordFolder()!.appendingPathComponent(QuizRecordNote.fileName(for: source))
    }

    // MARK: - 목록

    func testLoadsQuizBooksFromConfiguredFolder() async {
        let source = writeQuizBook()
        await app.loadQuizBooks()

        XCTAssertEqual(app.quizBooks.count, 1)
        let book = try? XCTUnwrap(app.quizBooks.first)
        XCTAssertEqual(book?.sourceURL.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(book?.itemCount, 3)
        XCTAssertFalse(book?.isStarted ?? true)          // 아직 기록장이 없다
        XCTAssertEqual(book?.dueCount, 3)                // 안 푼 문제집은 전부 오늘 몫
        XCTAssertNil(app.quizError)
    }

    /// 문제로 읽히지 않는 평범한 노트는 목록에 올리지 않는다.
    func testIgnoresNonQuizMarkdown() async {
        writeQuizBook()
        try? "# 그냥 메모\n\n오늘 할 일".write(
            to: quizFolder.appendingPathComponent("메모.md"), atomically: true, encoding: .utf8)
        await app.loadQuizBooks()
        XCTAssertEqual(app.quizBooks.count, 1)
    }

    /// 기록장 폴더 자신은 훑지 않는다(자기가 만든 파일을 문제집으로 오인하지 않게).
    func testSkipsRecordFolderWhenScanning() async {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        app.closeQuizBook()
        app.settings.quizFolders = [quizFolder.path, app.quizRecordFolder()!.path]

        await app.loadQuizBooks()
        XCTAssertEqual(app.quizBooks.count, 1)
    }

    // MARK: - 열기

    func testOpeningBookCreatesRecordNoteAndLoadsQuestions() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)

        XCTAssertEqual(app.quizItems.count, 3)
        XCTAssertEqual(app.quizItems.map(\.answer), [2, 1, 3])
        XCTAssertEqual(app.quizTypes, ["A. 옳은 것 고르기", "B. 옳지 않은 것 고르기"])
        XCTAssertNil(app.quizError)

        // 기록장이 새로 생기고, 원본은 그대로다.
        let record = recordURL(for: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
        let recordText = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(QuizRecordNote.parse(recordText)?.records.count, 3)
        XCTAssertFalse(recordText.contains("첫째 발문"), "기록장에 문제 내용이 들어갔다")
    }

    /// 원본 문제집은 여는 것만으로도, 채점 후에도 한 글자도 바뀌지 않는다.
    func testOriginalBookIsNeverModified() async throws {
        let source = writeQuizBook()
        let before = try String(contentsOf: source, encoding: .utf8)

        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 2)
        await app.pickQuizChoice(itemNumber: 2, choice: 2)

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), before)
    }

    func testReopeningBookKeepsPreviousProgress() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 2)          // 정답
        app.closeQuizBook()

        await app.openQuizBook(source)
        let item = try XCTUnwrap(app.quizItems.first { $0.n == 1 })
        XCTAssertEqual(item.state.reps, 1, "기록장에 남은 복습 상태를 다시 읽어야 한다")
        XCTAssertNil(item.picked, "이번 판의 정오 표시는 새로 시작한다")
    }

    // MARK: - 풀기

    func testCorrectPickGradesAsKnew() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 2)

        let item = try XCTUnwrap(app.quizItems.first { $0.n == 1 })
        XCTAssertTrue(item.isCorrect)
        XCTAssertEqual(item.state.reps, 1)
        XCTAssertEqual(item.state.lapses, 0)
        XCTAssertFalse(item.explanationShown, "맞히면 해설을 억지로 펴지 않는다")
        XCTAssertEqual(app.quizCorrectCount, 1)
        XCTAssertEqual(app.quizWrongCount, 0)
    }

    func testWrongPickGradesAsForgotAndOpensExplanation() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 1)          // 오답

        let item = try XCTUnwrap(app.quizItems.first { $0.n == 1 })
        XCTAssertFalse(item.isCorrect)
        XCTAssertEqual(item.state.lapses, 1)
        XCTAssertEqual(item.state.reps, 0)
        XCTAssertTrue(item.explanationShown, "틀리면 해설을 바로 펼쳐 준다")
        XCTAssertEqual(app.quizWrongCount, 1)
    }

    /// 한 문항은 한 번만 채점된다(고른 뒤에는 잠긴다).
    func testSecondPickIsIgnored() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 1)          // 오답
        await app.pickQuizChoice(itemNumber: 1, choice: 2)          // 다시 눌러도 무시

        let item = try XCTUnwrap(app.quizItems.first { $0.n == 1 })
        XCTAssertEqual(item.picked, 1)
        XCTAssertEqual(item.state.lapses, 1, "두 번 채점되지 않아야 한다")
        XCTAssertEqual(item.state.reps, 0)
    }

    func testGradeIsWrittenToRecordNote() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 2, choice: 1)          // 정답

        let text = try String(contentsOf: recordURL(for: source), encoding: .utf8)
        let record = try XCTUnwrap(QuizRecordNote.parse(text)?.records.first { $0.n == 2 })
        XCTAssertEqual(record.state.reps, 1)
        // 나머지 문항은 그대로.
        XCTAssertEqual(QuizRecordNote.parse(text)?.records.first { $0.n == 1 }?.state.reps, 0)
    }

    /// 그 사이 기록장이 바뀌었으면 저장하지 않고 안내한다.
    func testGradeFailsWhenRecordChangedMeanwhile() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        try "망가진 내용".write(to: recordURL(for: source), atomically: true, encoding: .utf8)

        await app.pickQuizChoice(itemNumber: 1, choice: 2)
        XCTAssertNotNil(app.quizError)
    }

    // MARK: - 필터 · 다시 풀기

    func testFilters() async {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 1)          // 오답
        await app.pickQuizChoice(itemNumber: 2, choice: 1)          // 정답

        app.quizFilter = .all
        XCTAssertEqual(app.visibleQuizItems.count, 3)
        app.quizFilter = .wrong
        XCTAssertEqual(app.visibleQuizItems.map(\.n), [1])
        app.quizFilter = .unsolved
        XCTAssertEqual(app.visibleQuizItems.map(\.n), [3])
        app.quizFilter = .type("B. 옳지 않은 것 고르기")
        XCTAssertEqual(app.visibleQuizItems.map(\.n), [3])
    }

    /// "이번 판 다시 풀기"는 화면 표시만 지우고 **기록장은 건드리지 않는다**.
    func testRestartRoundKeepsRecordNote() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 1)          // 오답
        let before = try String(contentsOf: recordURL(for: source), encoding: .utf8)

        app.restartQuizRound()

        XCTAssertEqual(app.quizSolvedCount, 0)
        XCTAssertEqual(app.quizFilter, .all)
        XCTAssertEqual(try String(contentsOf: recordURL(for: source), encoding: .utf8), before,
                       "복습 기록은 지우지 않는다")
        // 앵커에 남은 '틀린 적 1회'는 화면에도 그대로 남아 있어야 한다.
        XCTAssertEqual(app.quizItems.first { $0.n == 1 }?.state.lapses, 1)
    }

    func testToggleExplanation() async {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 2, choice: 1)          // 정답 → 해설 접힌 상태

        app.toggleQuizExplanation(itemNumber: 2)
        XCTAssertTrue(app.quizItems.first { $0.n == 2 }?.explanationShown ?? false)
        app.toggleQuizExplanation(itemNumber: 2)
        XCTAssertFalse(app.quizItems.first { $0.n == 2 }?.explanationShown ?? true)
    }

    // MARK: - 원본 문항 수가 달라졌을 때

    func testOpeningAfterQuestionsAddedReconcilesRecord() async throws {
        let source = writeQuizBook()
        await app.openQuizBook(source)
        await app.pickQuizChoice(itemNumber: 1, choice: 2)
        app.closeQuizBook()

        // 원본에 4번 문항을 더한다.
        var md = try String(contentsOf: source, encoding: .utf8)
        md = md.replacingOccurrences(of: "# 정답 · 해설", with: """
        **4.** 넷째 발문
        ① 아
        ② 자

        # 정답 · 해설
        """)
        md += "\n**4. ②** 넷째 해설."
        try md.write(to: source, atomically: true, encoding: .utf8)

        await app.openQuizBook(source)
        XCTAssertEqual(app.quizItems.count, 4)
        XCTAssertEqual(app.quizItems.first { $0.n == 1 }?.state.reps, 1, "먼저 푼 기록은 남아야 한다")
        let text = try String(contentsOf: recordURL(for: source), encoding: .utf8)
        XCTAssertEqual(QuizRecordNote.parse(text)?.records.count, 4)
    }

    // MARK: - 화면 전환

    func testCloseReturnsToReader() async {
        writeQuizBook()
        app.openStudyQuizView()
        XCTAssertEqual(app.mainMode, .quiz)

        app.closeStudyQuiz()
        XCTAssertEqual(app.mainMode, .reader)
        XCTAssertTrue(app.quizItems.isEmpty)
        XCTAssertNil(app.quizOpenSource)
    }
}
