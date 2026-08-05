import Foundation

/// 문제 풀기 — 이미 만들어 둔 문제집(볼트 md)을 앱에서 눌러 푼다.
/// 형식 읽기는 `QuizImportParser`, 기록장 형식은 `QuizRecordNote`(둘 다 순수)에 있고,
/// 이 파일은 화면 상태 + 실제 파일 읽기·쓰기만 잇는다(진도 관리와 같은 어법).
///
/// **원본 문제집은 절대 건드리지 않는다.** 발문·보기·정답·해설은 원본에서 읽기만 하고,
/// 앱이 쓰는 파일은 기록장 하나뿐이다(설계 §설계 변경 — 정답이 두 곳에 적히면 한쪽이 낡는다).
extension AppState {

    /// 기록장을 모아두는 폴더(학습 폴더 밑 "문제집기록").
    func quizRecordFolder() -> URL? {
        guard let base = effectiveStudyFolders().first else { return nil }
        return base.appendingPathComponent(QuizRecordNote.folderName, isDirectory: true)
    }

    // MARK: - 화면 진입 · 목록

    func openStudyQuizView() {
        mainMode = .quiz
    }

    @MainActor
    func closeStudyQuiz() {
        mainMode = .reader
        closeQuizBook()
        quizBooks = []
        quizError = nil
    }

    /// 문제집 목록을 다시 읽는다. 원본이 있는 폴더는 사용자가 등록한 학습 폴더 전부를 훑는다.
    @MainActor
    func loadQuizBooks() async {
        quizBusy = true
        quizError = nil
        defer { quizBusy = false }

        let folders = effectiveStudyFolders() + settings.quizFolders.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        guard !folders.isEmpty else {
            quizBooks = []
            quizError = "먼저 설정에서 볼트(노트 폴더)를 정해 주세요."
            return
        }

        let recordFolder = quizRecordFolder()
        let sources = Self.markdownFiles(in: folders)
        var books: [QuizBook] = []
        for sourceURL in sources {
            guard let content = try? String(contentsOf: sourceURL, encoding: .utf8) else { continue }
            let questions = QuizImportParser.parse(content).questions
            // 문제로 읽히지 않는 평범한 노트는 목록에 올리지 않는다.
            guard questions.count >= 2 else { continue }

            let recordURL = recordFolder?.appendingPathComponent(QuizRecordNote.fileName(for: sourceURL))
            let records = recordURL
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .flatMap { QuizRecordNote.parse($0) }?.records
            let exists = records != nil
            books.append(QuizBook(
                sourceURL: sourceURL,
                recordURL: exists ? recordURL : nil,
                itemCount: questions.count,
                dueCount: Self.dueCount(records: records, total: questions.count),
                solvedCount: (records ?? []).filter { $0.state.reps > 0 || $0.state.lapses > 0 }.count))
        }
        quizBooks = books.sorted { $0.title < $1.title }
        if quizBooks.isEmpty {
            quizError = "문제집을 찾지 못했습니다. 설정의 학습 폴더에 문제집 마크다운이 있는지 확인해 주세요."
        }
    }

    /// 오늘까지 풀어야 할 문항 수. 기록장이 없으면 전부 새 문항이다.
    private static func dueCount(records: [QuizRecord]?, total: Int, now: Date = Date()) -> Int {
        guard let records, !records.isEmpty else { return total }
        let cutoff = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        return records.filter { $0.state.due < cutoff }.count
    }

    /// 폴더(하위 폴더 포함)의 마크다운 파일 — 기록장 폴더 자신은 건너뛴다.
    private static func markdownFiles(in folders: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let manager = FileManager.default
        for folder in folders {
            guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension.lowercased() == "md" else { continue }
                guard !url.pathComponents.contains(QuizRecordNote.folderName) else { continue }
                let path = url.standardizedFileURL.path
                if seen.insert(path).inserted { out.append(url) }
            }
        }
        return out
    }

    // MARK: - 문제집 열기

    /// 문제집 하나를 연다. 기록장이 없으면 **이때 만든다**(문제집을 눌러 열겠다는 것이 곧 확인이다 —
    /// 새로 생기는 것은 기록장 한 개뿐이고 원본은 손대지 않는다).
    @MainActor
    func openQuizBook(_ sourceURL: URL) async {
        quizBusy = true
        quizError = nil
        defer { quizBusy = false }

        guard let content = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            quizError = "문제집 파일을 읽지 못했습니다: \(sourceURL.lastPathComponent)"
            return
        }
        let questions = QuizImportParser.parse(content).questions
        guard !questions.isEmpty else {
            quizError = "이 파일에서 문제를 찾지 못했습니다."
            return
        }
        guard let recordFolder = quizRecordFolder() else {
            quizError = "먼저 설정에서 볼트(노트 폴더)를 정해 주세요."
            return
        }

        let recordURL = recordFolder.appendingPathComponent(QuizRecordNote.fileName(for: sourceURL))
        let records: [QuizRecord]
        do {
            records = try loadOrCreateQuizRecords(at: recordURL, folder: recordFolder,
                                                  sourceURL: sourceURL, itemCount: questions.count)
        } catch {
            quizError = "기록장을 만들지 못했습니다: \(error.localizedDescription)"
            return
        }

        let byNumber = Dictionary(uniqueKeysWithValues: records.map { ($0.n, $0.state) })
        quizItems = questions.enumerated().map { index, question in
            let number = index + 1
            return QuizItem(n: number, question: question,
                            state: byNumber[number] ?? .initial())
        }
        quizTypes = Self.orderedTypes(of: questions)
        quizOpenSource = sourceURL
        quizRecordURL = recordURL
        quizFilter = .all
    }

    /// 기록장을 읽고, 없으면 만들고, 원본 문항 수가 달라졌으면 맞춘다.
    private func loadOrCreateQuizRecords(at recordURL: URL, folder: URL,
                                         sourceURL: URL, itemCount: Int) throws -> [QuizRecord] {
        let manager = FileManager.default
        if let content = try? String(contentsOf: recordURL, encoding: .utf8),
           let parsed = QuizRecordNote.parse(content) {
            guard let reconciled = QuizRecordNote.reconciling(content: content, itemCount: itemCount) else {
                return parsed.records
            }
            try reconciled.write(to: recordURL, atomically: true, encoding: .utf8)
            return QuizRecordNote.parse(reconciled)?.records ?? parsed.records
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = QuizRecordNote.build(sourceURL: sourceURL, bookURL: quizBookURL(near: sourceURL),
                                        itemCount: itemCount, noteFolder: folder)
        try note.write(to: recordURL, atomically: true, encoding: .utf8)
        return QuizRecordNote.parse(note)?.records ?? []
    }

    /// 문제집과 같은 폴더에 있는 교재 PDF(해설의 쪽으로 교재를 열 때 쓴다). 없으면 nil.
    private func quizBookURL(near sourceURL: URL) -> URL? {
        let folder = sourceURL.deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension.lowercased() == "pdf" }
    }

    /// 문제집에 나온 차례대로 형식 이름을 모은다(중복 없이).
    private static func orderedTypes(of questions: [StudyQuestion]) -> [String] {
        var out: [String] = []
        for question in questions where !question.type.isEmpty && !out.contains(question.type) {
            out.append(question.type)
        }
        return out
    }

    @MainActor
    func closeQuizBook() {
        quizOpenSource = nil
        quizRecordURL = nil
        quizItems = []
        quizTypes = []
        quizFilter = .all
    }

    // MARK: - 풀기

    /// 화면에 보일 문항(필터 적용).
    var visibleQuizItems: [QuizItem] {
        quizItems.filter { quizFilter.matches($0) }
    }

    var quizSolvedCount: Int { quizItems.filter(\.isSolved).count }
    var quizCorrectCount: Int { quizItems.filter { $0.isSolved && $0.isCorrect }.count }
    var quizWrongCount: Int { quizItems.filter { $0.isSolved && !$0.isCorrect }.count }

    /// 보기를 고른다 — **한 문항은 한 번만 채점된다**(고른 뒤에는 잠긴다, mediaedu와 같은 규칙).
    /// 맞으면 "앎", 틀리면 "모름"으로 그 자리에서 복습 기록에 반영한다.
    @MainActor
    func pickQuizChoice(itemNumber: Int, choice: Int) async {
        guard let index = quizItems.firstIndex(where: { $0.n == itemNumber }),
              !quizItems[index].isSolved else { return }
        quizItems[index].picked = choice
        // 틀렸으면 해설을 바로 펼쳐 준다(왜 틀렸는지가 그 자리에서 궁금하다).
        let correct = quizItems[index].isCorrect
        if !correct { quizItems[index].explanationShown = true }
        await saveQuizGrade(index: index, outcome: correct ? .knew : .forgot)
    }

    /// 채점 결과를 기록장에 남긴다 — 그 문항 앵커 한 줄만 바꾸고 백업 1부를 남긴다.
    /// 그 사이 파일이 바뀌었으면 포기하고 안내한다(복습 채점과 같은 규약).
    @MainActor
    private func saveQuizGrade(index: Int, outcome: ReviewOutcome) async {
        guard let recordURL = quizRecordURL else { return }
        let item = quizItems[index]
        guard let content = try? String(contentsOf: recordURL, encoding: .utf8) else {
            quizError = "기록장을 읽지 못했습니다: \(recordURL.lastPathComponent)"
            return
        }
        let expected = QuizRecordNote.formatAnchorLine(QuizRecord(n: item.n, state: item.state))
        let newState = ReviewScheduler.grade(item.state, outcome: outcome)
        guard let updated = QuizRecordNote.replacingAnchorLine(
            in: content, number: item.n, expectedLineText: expected, newState: newState
        ) else {
            quizError = "기록장이 그 사이 바뀌어서 저장하지 못했습니다. 문제집을 다시 열어 주세요."
            return
        }
        do {
            // 백업 1부(§3.6) — 덮어쓰기 직전 원본 그대로. 실패해도 채점 자체는 막지 않는다.
            try? content.write(to: URL(fileURLWithPath: recordURL.path + ".bak"),
                               atomically: true, encoding: .utf8)
            try updated.write(to: recordURL, atomically: true, encoding: .utf8)
        } catch {
            quizError = "저장 실패: \(error.localizedDescription)"
            return
        }
        quizItems[index].state = newState
    }

    @MainActor
    func toggleQuizExplanation(itemNumber: Int) {
        guard let index = quizItems.firstIndex(where: { $0.n == itemNumber }) else { return }
        quizItems[index].explanationShown.toggle()
    }

    /// "이번 판 다시 풀기" — 화면의 정오 표시만 지운다. **기록장은 건드리지 않는다**
    /// (복습 기록을 지우면 되돌릴 수 없다 — mediaedu의 "기록 초기화"와 뜻이 다르다).
    @MainActor
    func restartQuizRound() {
        for index in quizItems.indices {
            quizItems[index].picked = nil
            quizItems[index].explanationShown = false
        }
        quizFilter = .all
        quizError = nil
    }

    // MARK: - 교재 원본 열기

    /// 해설의 쪽(`loc`)으로 교재를 연다 — 없으면 false(호출부가 조용히 넘긴다).
    @MainActor
    @discardableResult
    func openQuizSource(itemNumber: Int) -> Bool {
        guard let item = quizItems.first(where: { $0.n == itemNumber }),
              let recordURL = quizRecordURL,
              let content = try? String(contentsOf: recordURL, encoding: .utf8),
              let parsed = QuizRecordNote.parse(content),
              let relative = parsed.book,
              let bookURL = StudySourceLink.sourceURL(relativePath: relative,
                                                      noteFolder: recordURL.deletingLastPathComponent()),
              FileManager.default.fileExists(atPath: bookURL.path)
        else { return false }
        openDocument(at: bookURL, inNewTab: true,
                     scrollToLine: StudySourceLink.line(of: item.question.locator),
                     scrollToPDFPage: StudySourceLink.page(of: item.question.locator))
        return true
    }
}
