import Foundation
import AppKit
import UniformTypeIdentifiers
import PDFKit

/// 학습도우미(Study Helper) S1 — `StudyHelperView` 배선. 실제 로직은 전부 `Study*`
/// (Models/Services)에 있고, 이 파일은 화면 진입점 + AppState 상태만 잇는다
/// (설계 문서 `docs/superpowers/specs/2026-07-31-study-helper-design.md`).
extension AppState {

    /// 청크 예산(글자 수, 위치 태그·구분자 포함, §4.2.5) — 아직 설정 화면에 노출된 값이 아니라
    /// S1 첫 화면의 잠정 기본값(추후 설정 키로 승격 가능, `docs/todolist.md` 참고).
    static let studyChunkBudget = 8_000

    // MARK: - 범위 선택

    /// 학습도우미를 연다 — 레고 2026-08-01 요청("교재파일은 직전에 선택한 파일을 기억해줄래?
    /// 매번 선택하려니 귀찮다"). 이미 골라둔 파일이 있으면(같은 세션에서 이미 열어본 경우)
    /// 그대로 두고, 없으면 지난번에 고른 파일(`settings.lastStudySourcePath`)을 시도한다 —
    /// 그 사이 파일이 지워지거나 옮겨졌을 수 있어 실존 확인 후에만 복원하고, 실패해도 조용히
    /// "파일을 선택하세요" 빈 상태로 열릴 뿐 에러를 띄우지 않는다(사용자가 시작한 동작이 아니라
    /// 편의 복원이라 실패가 눈에 띄면 오히려 방해된다).
    func openStudyHelper() {
        mainMode = .study
        guard studyScopeFileURL == nil,
              let path = settings.lastStudySourcePath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path),
              let kind = Self.studyDocumentKind(for: url) else { return }
        applyStudySelection(url: url, kind: kind)
    }

    /// 학습도우미 화면 닫기(다듬기 C) — 만들던 중이면 claude 호출도 끊고 파일 화면으로 돌아간다.
    @MainActor
    func closeStudyHelper() {
        cancelStudyGeneration()
        mainMode = .reader
    }

    /// 학습할 파일 선택 — 학습도우미가 지원하는 종류만(PDF·마크다운/텍스트·오피스·이미지,
    /// `StudySourceLoader` 지원 범위와 동일). 미디어·QuickLook 전용 파일은 목록에서 제외.
    func pickStudySourceFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, UTType(filenameExtension: "md")!,
                               .png, .jpeg, .heic, .webP, .gif, .pdf]
        types += DocumentKind.officeExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url,
              let kind = Self.studyDocumentKind(for: url) else { return }

        applyStudySelection(url: url, kind: kind)
        // 다음에 학습도우미를 열 때 이 파일을 기억한다("매번 선택하려니 귀찮다" 요청).
        settings.lastStudySourcePath = url.path
        saveUserData()
    }

    /// `pickStudySourceFile()`·`openStudyHelper()`(복원)가 공유하는 실제 선택 적용 — 미리보기·
    /// 저장 상태 초기화 + 범위 메타데이터 비동기 로드까지 항상 같은 순서로 실행되게 한다.
    private func applyStudySelection(url: URL, kind: DocumentKind) {
        studyScopeFileURL = url
        studyScopeKind = kind
        studyPreviewCards = []
        studyPreviewQuestions = []
        studyOutcomeSummary = nil
        studySavedNoteURL = nil
        studyError = nil
        studyUseWholeFile = true
        resetStudyRangeMetadata()
        Task { await loadStudyRangeMetadata(kind: kind, url: url) }
    }

    private static func studyDocumentKind(for url: URL) -> DocumentKind? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.pdfExtensions.contains(ext) { return .pdf }
        if DocumentKind.markdownExtensions.contains(ext) { return .markdown }
        if DocumentKind.officeExtensions.contains(ext) { return .office }
        if DocumentKind.imageExtensions.contains(ext) { return .image }
        return nil
    }

    private func resetStudyRangeMetadata() {
        studyPDFPageCount = 0
        studyPageRangeStart = 1
        studyPageRangeEnd = 1
        studyHeadingChoices = []
        studyLineCount = 0
        studyHeadingRangeStartIndex = 0
        studyHeadingRangeEndIndex = 0
        studySectionChoices = []
        studySectionRangeStart = 1
        studySectionRangeEnd = 1
        studyRangeLoading = false
    }

    /// 종류별 부분 범위 선택 목록을 채운다(레고 2026-08-01 피드백 — "교재 전체를 한 번에
    /// 넣는 건 비현실적"). PDF는 쪽수만 세면 되지만, 오피스는 kordoc 변환이 끝나야 헤딩을
    /// 알 수 있어 그동안 `studyRangeLoading`을 켠다. 이미지는 나눌 단위가 없어 항상 전체.
    @MainActor
    func loadStudyRangeMetadata(kind: DocumentKind, url: URL) async {
        switch kind {
        case .pdf:
            let pageCount = PDFDocument(url: url)?.pageCount ?? 0
            studyPDFPageCount = pageCount
            studyPageRangeStart = 1
            studyPageRangeEnd = max(1, pageCount)
        case .markdown:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { break }
            let lines = content.components(separatedBy: .newlines)
            studyLineCount = lines.count
            studyHeadingChoices = TOCBuilder.extractHeadings(from: content)
                .sorted { $0.lineNumber < $1.lineNumber }
                .map { StudyHeadingChoice(title: $0.text, lineNumber: $0.lineNumber) }
            studyHeadingRangeStartIndex = 0
            studyHeadingRangeEndIndex = max(0, studyHeadingChoices.count - 1)
        case .office:
            studyRangeLoading = true
            defer { studyRangeLoading = false }
            guard let markdown = try? await kordocService.markdown(for: url) else { break }
            let labeled = StudySourceLoader.labeledSections(from: markdown)
            studySectionChoices = labeled.map { StudySectionChoice(title: $0.title, index: $0.index) }
            studySectionRangeStart = 1
            studySectionRangeEnd = max(1, labeled.count)
        case .image, .media, .quickLook:
            break // 나눌 단위가 없어 항상 전체 파일(§5.2).
        }
        await updateStudyPreviewPlan()
    }

    /// 현재 선택된 학습 범위 — "전체" 토글이 켜져 있거나 부분 선택 데이터가 없으면 전체 파일.
    /// internal — 대화(S3, `AppState+StudyChat.swift`)도 같은 범위 선택 UI를 그대로 재사용한다.
    func currentStudyScope() -> StudyScope? {
        guard let url = studyScopeFileURL, let kind = studyScopeKind else { return nil }
        return StudyScope(fileURL: url, kind: kind, range: currentStudyRange(kind: kind))
    }

    private func currentStudyRange(kind: DocumentKind) -> StudyScopeRange {
        guard !studyUseWholeFile else { return .wholeFile }
        switch kind {
        case .pdf:
            guard studyPDFPageCount > 0 else { return .wholeFile }
            return .pageRange(studyPageRangeStart, studyPageRangeEnd)
        case .markdown:
            guard !studyHeadingChoices.isEmpty,
                  studyHeadingRangeStartIndex < studyHeadingChoices.count,
                  studyHeadingRangeEndIndex < studyHeadingChoices.count else { return .wholeFile }
            let startLine = studyHeadingChoices[studyHeadingRangeStartIndex].lineNumber
            let endLine = (studyHeadingRangeEndIndex + 1 < studyHeadingChoices.count)
                ? studyHeadingChoices[studyHeadingRangeEndIndex + 1].lineNumber - 1
                : studyLineCount
            return .lineRange(startLine, endLine)
        case .office:
            guard !studySectionChoices.isEmpty else { return .wholeFile }
            return .sectionRange(studySectionRangeStart, studySectionRangeEnd)
        case .image, .media, .quickLook:
            return .wholeFile
        }
    }

    /// 직접입력(TextField)으로 고친 쪽 번호가 문서 쪽수를 벗어나거나 시작>끝이 되지 않게 정리한다.
    /// 어느 필드를 방금 고쳤는지에 따라 반대쪽을 밀어준다(레고 2026-08-01 요청 — 스테퍼 대신 직접입력).
    enum StudyPageRangeField { case start, end }

    @MainActor
    func clampStudyPageRange(changed field: StudyPageRangeField) {
        guard studyPDFPageCount > 0 else { return }
        studyPageRangeStart = min(max(1, studyPageRangeStart), studyPDFPageCount)
        studyPageRangeEnd = min(max(1, studyPageRangeEnd), studyPDFPageCount)
        switch field {
        case .start:
            if studyPageRangeEnd < studyPageRangeStart { studyPageRangeEnd = studyPageRangeStart }
        case .end:
            if studyPageRangeStart > studyPageRangeEnd { studyPageRangeStart = studyPageRangeEnd }
        }
    }

    // MARK: - 사전 분량 표시(AC #9) — AI 호출 없이 청크 수·글자 수만 계산.

    @MainActor
    func updateStudyPreviewPlan() async {
        guard let scope = currentStudyScope() else {
            studyPreviewCharCount = 0
            studyPreviewChunkCount = 0
            return
        }
        let segments = await studySourceLoader.segments(for: scope)
        let chunks = StudyChunker.chunks(from: segments, budget: Self.studyChunkBudget)
        studyPreviewChunkCount = chunks.count
        studyPreviewCharCount = chunks.reduce(0) { $0 + $1.charCount }
    }

    // MARK: - 템플릿(레고 2026-08-01 요청 — "정리카드나 연습문제 템플릿을 만들거나 수정")

    /// 지금 고른 종류(카드/문제)에 맞는 템플릿만 — 화면 Picker·선택 유효성 검사 공용.
    func studyTemplates(for kind: StudyItemKind) -> [StudyTemplate] {
        settings.studyTemplates.filter { $0.kind == kind }
    }

    /// 현재 선택된 템플릿의 추가 지시문 — 선택 없음("기본")이거나 다른 종류로 바뀌어 못 찾으면 "".
    private var studySelectedTemplateInstructions: String {
        guard let id = studySelectedTemplateID else { return "" }
        return settings.studyTemplates.first(where: { $0.id == id })?.instructions ?? ""
    }

    // MARK: - 생성(AI 실호출)

    /// "만들기" 진입점 — 취소 가능한 태스크로 감싼다(다듬기 B, `startWikiMerge` 전례).
    @MainActor
    func startStudyGeneration() {
        studyGenerateTask?.cancel()
        studyGenerateTask = Task { @MainActor [weak self] in
            await self?.generateStudyItems()
            self?.studyGenerateTask = nil
        }
    }

    /// "취소" — 진행 중이던 claude 호출을 끊는다(ClaudeService 폴링 루프가 프로세스를 종료).
    /// 유휴 상태면 무동작이라 창을 닫을 때 무조건 불러도 안전하다.
    @MainActor
    func cancelStudyGeneration() {
        studyGenerateTask?.cancel()
        studyGenerateTask = nil
    }

    @MainActor
    func generateStudyItems() async {
        guard let scope = currentStudyScope() else {
            studyError = "먼저 학습할 파일을 선택하세요."
            return
        }
        studyBusy = true
        studyError = nil
        studyPreviewCards = []
        studyPreviewQuestions = []
        studyOutcomeSummary = nil
        studySavedNoteURL = nil
        studyProgress = nil
        studyProgressDone = 0
        studyProgressTotal = 0
        defer { studyBusy = false; studyProgress = nil }

        let extraInstructions = studySelectedTemplateInstructions
        do {
            switch studyGenerationKind {
            case .card:
                let outcome = try await studyService.generateCards(
                    scope: scope, count: studyRequestedCount, chunkBudget: Self.studyChunkBudget,
                    extraInstructions: extraInstructions,
                    onProgress: { [weak self] done, total in
                        Task { @MainActor in self?.applyStudyProgress(done: done, total: total) }
                    })
                studyPreviewCards = outcome.items
                studyOutcomeSummary = Self.studyOutcomeSummary(chunkCount: outcome.chunkCount,
                                                                 succeeded: outcome.succeededChunkCount,
                                                                 invalidCitations: outcome.invalidCitations)
            case .question:
                let outcome = try await studyService.generateQuestions(
                    scope: scope, count: studyRequestedCount, chunkBudget: Self.studyChunkBudget,
                    extraInstructions: extraInstructions,
                    onProgress: { [weak self] done, total in
                        Task { @MainActor in self?.applyStudyProgress(done: done, total: total) }
                    })
                studyPreviewQuestions = outcome.items
                studyOutcomeSummary = Self.studyOutcomeSummary(chunkCount: outcome.chunkCount,
                                                                 succeeded: outcome.succeededChunkCount,
                                                                 invalidCitations: outcome.invalidCitations)
            }
        } catch StudyService.GenerationError.emptyContent {
            studyError = "선택한 파일에서 읽을 수 있는 글자가 없습니다 — 다른 파일을 선택하거나, 사진이면 글자가 잘 읽히는지 확인하세요."
        } catch StudyService.GenerationError.allChunksFailed {
            studyError = "AI가 계속 형식에 안 맞는 답을 줘서 카드/문제를 만들지 못했습니다. 잠시 후 다시 시도해 주세요."
        } catch ClaudeError.notLoggedIn {
            studyError = "Claude 로그인이 필요합니다. 설정에서 로그인해 주세요."
        } catch ClaudeError.creditExhausted {
            studyError = "Claude 사용량이 소진됐습니다. 잠시 후 다시 시도해 주세요."
        } catch ClaudeError.timeout {
            studyError = "응답이 너무 오래 걸려 중단했습니다. 잠시 후 다시 시도해 주세요."
        } catch ClaudeError.toolNotFound {
            studyError = "claude 명령을 찾지 못했습니다. 설정 > Tools에서 설치 경로를 확인하세요."
        } catch is CancellationError {
            // 사용자가 스스로 멈춘 것 — 오류가 아니므로 빨간 글씨를 띄우지 않는다.
            studyOutcomeSummary = "만들기를 취소했습니다."
        } catch {
            studyError = "생성에 실패했습니다: \(error.localizedDescription)"
        }
    }

    /// 진행 표시 문구·막대 — 조각이 하나뿐이면 "몇/몇"이 의미가 없어 기본 문구를 그대로 둔다.
    @MainActor
    func applyStudyProgress(done: Int, total: Int) {
        guard studyBusy, total > 1 else { return }
        studyProgressDone = done
        studyProgressTotal = total
        studyProgress = "조각 \(done)/\(total) 만드는 중…"
    }

    /// 진행 막대 값(0~1) — 지금 조각을 시작한 시점이라 "done-1개 완료"로 본다.
    var studyProgressFraction: Double {
        guard studyProgressTotal > 0 else { return 0 }
        return min(1, max(0, Double(studyProgressDone - 1) / Double(studyProgressTotal)))
    }

    /// AC #24 "청크 C개 중 k개 성공" 요약 — 무효 인용이 있으면 한 줄 덧붙인다(O4).
    private static func studyOutcomeSummary(chunkCount: Int, succeeded: Int, invalidCitations: Int) -> String {
        var text = "조각 \(chunkCount)개 중 \(succeeded)개 성공"
        if invalidCitations > 0 {
            text += " · 청크 밖 근거 \(invalidCitations)건은 위치 표시를 지웠어요"
        }
        return text
    }

    // MARK: - 저장(제안 → 확인 → 실행, AC #6)

    @MainActor
    func saveStudyNote() async {
        guard let scope = currentStudyScope() else { return }
        guard !studyPreviewCards.isEmpty || !studyPreviewQuestions.isEmpty else {
            studyError = "저장할 카드/문제가 없습니다. 먼저 만들기를 눌러주세요."
            return
        }
        guard let vault = defaultVault else {
            studyError = "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요."
            return
        }

        let targetDir = vault.rootPath.appendingPathComponent(effectiveSendFolder(for: vault))
        let sourceName = scope.fileURL.deletingPathExtension().lastPathComponent

        do {
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            let title: String
            let result: StudyNoteWriter.BuildResult
            switch studyGenerationKind {
            case .card:
                title = "\(sourceName) 카드"
                result = StudyNoteWriter.buildCardNote(cards: studyPreviewCards, scope: scope,
                                                        noteFolder: targetDir, title: title)
            case .question:
                title = "\(sourceName) 문제"
                result = StudyNoteWriter.buildQuestionNote(questions: studyPreviewQuestions, scope: scope,
                                                            noteFolder: targetDir, title: title)
            }
            let filename = Self.sanitizedFilename(title) + ".md"
            let targetURL = targetDir.appendingPathComponent(filename).uniquified()
            try result.body.write(to: targetURL, atomically: true, encoding: .utf8)
            studySavedNoteURL = targetURL
            loadFileTree()
        } catch {
            studyError = "노트 저장 실패: \(error.localizedDescription)"
        }
    }

    /// 저장 직후 "노트 열기" — 사용자가 눌러야만 연다(자동 열기 없음).
    @MainActor
    func openSavedStudyNote() {
        guard let url = studySavedNoteURL else { return }
        openDocument(at: url, inNewTab: true)
    }
}
