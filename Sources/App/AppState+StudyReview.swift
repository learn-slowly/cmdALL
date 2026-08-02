import Foundation

/// 학습도우미 복습(S2) — `StudyReviewView` 배선. `ReviewScheduler`(채점 계산)·`StudyNoteParser`
/// (앵커 읽기/쓰기)·`StudyIndex`(캐시)는 전부 순수/actor로 별도 파일에 있고, 이 파일은 화면
/// 진입점 + 실제 파일 IO(백업·재확인·치환)만 잇는다(설계 문서 §3, `2026-07-31-study-helper-design.md`).
extension AppState {

    /// 재빌드 범위(§3.7) — 설정에 등록한 폴더가 있으면 그것만, 없으면 "카드/문제 노트 저장
    /// 위치 1곳"(기본 볼트의 발송 폴더, S1 저장 경로와 동일 계산)을 기본값으로 쓴다.
    func effectiveStudyFolders() -> [URL] {
        if !settings.studyFolders.isEmpty {
            return settings.studyFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        guard let vault = defaultVault else { return [] }
        return [vault.rootPath.appendingPathComponent(effectiveSendFolder(for: vault))]
    }

    /// 설정 화면 "학습 폴더" 손으로 추가 — 등록되면 기본값(발송 폴더 1곳) 대신 설정 목록만 쓴다.
    @MainActor
    func registerStudyFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !settings.studyFolders.contains(path) else { return }
        settings.studyFolders.append(path)
        saveUserData()
        Task { await rebuildStudyIndex() }
    }

    @MainActor
    func unregisterStudyFolder(_ path: String) {
        settings.studyFolders.removeAll { $0 == path }
        saveUserData()
        Task { await rebuildStudyIndex() }
    }

    /// 캐시 재빌드(§3.7 트리거: 앱 시작 1회·폴더 변경·캐시 없음/실패·수동). 등록 폴더가 없으면
    /// 조용히 건너뛴다(볼트 미설정 상태에선 학습도우미 자체를 아직 못 썼을 것).
    @MainActor
    func rebuildStudyIndex() async {
        let folders = effectiveStudyFolders()
        guard !folders.isEmpty else {
            studyDueCount = 0
            return
        }
        let summary = await studyIndex.rebuild(folders: folders)
        studyReviewRebuildNotice = "학습 목록을 다시 훑었습니다: \(summary.included)건(제외 \(summary.excluded))"
        await refreshStudyDueCount()
    }

    @MainActor
    func refreshStudyDueCount() async {
        studyDueCount = await studyIndex.dueItems().count
    }

    // MARK: - 오늘 복습 화면

    /// 진입점(사이드바 리본·메뉴·커맨드 팔레트) 공용 — 시트를 연다. 실제 데이터 로드는
    /// `StudyReviewView`의 `.task`(→ `openStudyReview()`)가 맡는다.
    func openStudyReviewSheet() {
        showStudyReview = true
    }

    @MainActor
    func openStudyReview() async {
        showStudyReview = true
        studyReviewBusy = true
        studyReviewError = nil
        studyReviewQueue = await studyIndex.dueItems()
        studyReviewIndex = 0
        studyReviewRevealAnswer = false
        studyReviewUndo = nil
        studyReviewBusy = false
    }

    /// "학습 목록 다시 훑기" 버튼 — 재빌드 후 대기열을 새로 불러온다(수동 트리거, §3.7).
    @MainActor
    func refreshStudyReview() async {
        studyReviewBusy = true
        await rebuildStudyIndex()
        studyReviewQueue = await studyIndex.dueItems()
        studyReviewIndex = 0
        studyReviewRevealAnswer = false
        studyReviewUndo = nil
        studyReviewBusy = false
    }

    @MainActor
    func closeStudyReview() {
        showStudyReview = false
        studyReviewQueue = []
        studyReviewIndex = 0
        studyReviewRevealAnswer = false
        studyReviewUndo = nil
        studyReviewError = nil
    }

    var currentStudyReviewItem: StudyIndexItem? {
        guard studyReviewIndex >= 0, studyReviewIndex < studyReviewQueue.count else { return nil }
        return studyReviewQueue[studyReviewIndex]
    }

    @MainActor
    func revealStudyReviewAnswer() {
        studyReviewRevealAnswer = true
    }

    /// 노트 파일을 연다(§3.10 원본 불변 — 여는 것은 항상 앱이 만든 학습 노트, 교재 원본이 아니다).
    @MainActor
    func openCurrentStudyReviewNote() {
        guard let item = currentStudyReviewItem else { return }
        openDocument(at: URL(fileURLWithPath: item.notePath), inNewTab: true)
    }

    /// 근거 태그(`[[p9]]`) 클릭 — 학습 노트가 열려 있으면 **원본 교재**의 그 쪽/줄을 연다.
    /// 위치 태그가 아니거나(=평범한 위키링크) 원본 파일을 못 찾으면 false를 돌려 기존
    /// 노트 찾기로 넘긴다(§`StudySourceLink`, 레고 2026-08-01).
    @discardableResult
    func openStudyEvidence(tag: String) -> Bool {
        guard let locator = StudySourceLink.locator(fromTag: tag),
              let noteURL = currentTabFileURL else { return false }
        // 항목 앵커·frontmatter는 **디스크 원문**에서만 읽는다 — 화면 버퍼(`currentDocument.content`)는
        // frontmatter가 떼어진 본문이라 `study_id`가 없어 학습 노트로 인식되지 않는다(2026-08-01 실측).
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8),
              let relative = StudySourceLink.sourceRelativePath(for: locator, in: content) else { return false }
        guard openStudySource(relativePath: relative, noteURL: noteURL, locator: locator) else {
            // 학습 노트의 근거 태그가 맞는데 원본만 없는 경우 — 노트 이름으로 다시 찾아봐야
            // 헛수고이므로 여기서 끝내고 이유를 알려준다.
            showToast("원본 자료를 찾지 못했습니다(옮겼거나 지웠을 수 있어요).")
            return true
        }
        return true
    }

    /// "원본 보기"(복습 화면) — 노트 파일을 디스크에서 읽어 원본 교재의 그 위치를 연다.
    @MainActor
    @discardableResult
    func openCurrentStudyReviewSource() -> Bool {
        guard let item = currentStudyReviewItem else { return false }
        let noteURL = URL(fileURLWithPath: item.notePath)
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8),
              let relative = StudySourceLink.sourceRelativePath(for: item.loc, in: content) else {
            studyReviewError = "원본 자료 위치를 노트에서 찾지 못했습니다."
            return false
        }
        guard openStudySource(relativePath: relative, noteURL: noteURL, locator: item.loc) else {
            studyReviewError = "원본 자료 파일을 찾지 못했습니다(옮겼거나 지웠을 수 있어요)."
            return false
        }
        showStudyReview = false
        return true
    }

    /// 공통 열기 — 파일이 실제로 있을 때만 연다(옮겼거나 지운 원본에 헛되이 탭을 열지 않는다).
    private func openStudySource(relativePath: String, noteURL: URL, locator: StudyLocator) -> Bool {
        guard let sourceURL = StudySourceLink.sourceURL(relativePath: relativePath,
                                                        noteFolder: noteURL.deletingLastPathComponent()),
              FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        openDocument(at: sourceURL, inNewTab: true,
                     scrollToLine: StudySourceLink.line(of: locator),
                     scrollToPDFPage: StudySourceLink.page(of: locator))
        return true
    }

    /// 채점(§3.6 "채점 쓰기") — 앵커 줄만 치환 + 백업 1부, 쓰기 직전 재확인(§3.6 "채점 직전
    /// 외부 변경"). 성공하면 캐시 한 행도 즉시 갱신하고 다음 항목으로 넘어간다.
    @MainActor
    func gradeCurrentStudyReviewItem(_ outcome: ReviewOutcome) async {
        guard let item = currentStudyReviewItem else { return }
        studyReviewBusy = true
        studyReviewError = nil
        defer { studyReviewBusy = false }

        let url = URL(fileURLWithPath: item.notePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            studyReviewError = "노트 파일을 읽지 못했습니다: \(url.lastPathComponent)"
            return
        }
        let newState = ReviewScheduler.grade(item.state, outcome: outcome)
        guard let newContent = StudyNoteParser.replacingAnchorLine(
            in: content, itemUID: item.uid, expectedLineText: item.lineText, newState: newState
        ) else {
            studyReviewError = "이 노트가 그 사이 바뀌어서 저장하지 못했습니다. \"학습 목록 다시 훑기\"로 새로고침해 주세요."
            return
        }

        do {
            // 백업 1부(§3.6) — 덮어쓰기 직전 원본 그대로. 실패해도 채점 자체는 막지 않는다
            // (백업은 안전망이지, 백업 실패가 정상 채점을 막을 이유는 아니다).
            let backupURL = URL(fileURLWithPath: url.path + ".bak")
            try? content.write(to: backupURL, atomically: true, encoding: .utf8)
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            studyReviewError = "저장 실패: \(error.localizedDescription)"
            return
        }

        let newLineText = StudyNoteParser.parse(newContent).items.first(where: { $0.uid == item.uid })?.lineText
            ?? StudyNoteWriter.formatAnchorLine(uid: item.uid, src: item.notePath, loc: item.loc, state: newState)
        await studyIndex.updateAfterGrading(itemUID: item.uid, newState: newState, newLineText: newLineText)

        studyReviewQueue[studyReviewIndex] = StudyIndexItem(
            uid: item.uid, studyID: item.studyID, notePath: item.notePath, kind: item.kind,
            loc: item.loc, title: item.title, body: item.body, state: newState, lineText: newLineText)
        studyReviewUndo = StudyReviewUndo(itemUID: item.uid, queueIndex: studyReviewIndex,
                                          previousState: item.state, previousLineText: item.lineText,
                                          gradedLineText: newLineText)
        studyReviewIndex += 1
        studyReviewRevealAnswer = false
        studyDueCount = max(0, studyDueCount - 1)
    }

    /// "되돌리기"(다듬기 A) — 방금 채점한 **직전 1건**만 원래 상태로 되돌린다. 채점과 같은 방식으로
    /// 앵커 줄만 치환하고 백업 1부를 남기며, 쓰기 직전 재확인이 어긋나면(그 사이 노트가 바뀌면)
    /// 포기한다. 되돌린 뒤 화면은 그 항목으로 돌아가고 정답이 펼쳐진 상태가 된다.
    @MainActor
    func undoLastStudyReviewGrade() async {
        guard let undo = studyReviewUndo,
              undo.queueIndex >= 0, undo.queueIndex < studyReviewQueue.count else {
            studyReviewUndo = nil
            return
        }
        let item = studyReviewQueue[undo.queueIndex]
        studyReviewBusy = true
        studyReviewError = nil
        defer { studyReviewBusy = false }

        let url = URL(fileURLWithPath: item.notePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            studyReviewError = "노트 파일을 읽지 못했습니다: \(url.lastPathComponent)"
            return
        }
        guard let newContent = StudyNoteParser.replacingAnchorLine(
            in: content, itemUID: undo.itemUID, expectedLineText: undo.gradedLineText,
            newState: undo.previousState
        ) else {
            studyReviewError = "이 노트가 그 사이 바뀌어서 되돌리지 못했습니다."
            studyReviewUndo = nil
            return
        }

        do {
            let backupURL = URL(fileURLWithPath: url.path + ".bak")
            try? content.write(to: backupURL, atomically: true, encoding: .utf8)
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            studyReviewError = "되돌리기 저장 실패: \(error.localizedDescription)"
            return
        }

        let restoredLineText = StudyNoteParser.parse(newContent).items.first(where: { $0.uid == undo.itemUID })?.lineText
            ?? undo.previousLineText
        await studyIndex.updateAfterGrading(itemUID: undo.itemUID, newState: undo.previousState,
                                            newLineText: restoredLineText)

        studyReviewQueue[undo.queueIndex] = StudyIndexItem(
            uid: item.uid, studyID: item.studyID, notePath: item.notePath, kind: item.kind,
            loc: item.loc, title: item.title, body: item.body,
            state: undo.previousState, lineText: restoredLineText)
        studyReviewIndex = undo.queueIndex
        studyReviewRevealAnswer = true
        studyDueCount += 1
        studyReviewUndo = nil
    }
}
