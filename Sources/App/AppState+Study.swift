import Foundation
import AppKit
import UniformTypeIdentifiers

/// 학습도우미(Study Helper) S1 — `StudyHelperView` 배선. 실제 로직은 전부 `Study*`
/// (Models/Services)에 있고, 이 파일은 화면 진입점 + AppState 상태만 잇는다
/// (설계 문서 `docs/superpowers/specs/2026-07-31-study-helper-design.md`).
extension AppState {

    /// 청크 예산(글자 수, 위치 태그·구분자 포함, §4.2.5) — 아직 설정 화면에 노출된 값이 아니라
    /// S1 첫 화면의 잠정 기본값(추후 설정 키로 승격 가능, `docs/todolist.md` 참고).
    static let studyChunkBudget = 8_000

    // MARK: - 범위 선택

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

        studyScopeFileURL = url
        studyScopeKind = kind
        studyPreviewCards = []
        studyPreviewQuestions = []
        studyOutcomeSummary = nil
        studySavedNoteURL = nil
        studyError = nil
        Task { await updateStudyPreviewPlan() }
    }

    private static func studyDocumentKind(for url: URL) -> DocumentKind? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.pdfExtensions.contains(ext) { return .pdf }
        if DocumentKind.markdownExtensions.contains(ext) { return .markdown }
        if DocumentKind.officeExtensions.contains(ext) { return .office }
        if DocumentKind.imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// 현재 선택된 학습 범위 — 부분 범위 선택 UI는 이번 화면에 없어 항상 전체 파일
    /// (`StudyScope`·`StudyChunker`는 이미 부분 범위를 지원하므로 후속 확장 여지).
    private func currentStudyScope() -> StudyScope? {
        guard let url = studyScopeFileURL, let kind = studyScopeKind else { return nil }
        return StudyScope(fileURL: url, kind: kind, range: .wholeFile)
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

    // MARK: - 생성(AI 실호출)

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
        defer { studyBusy = false }

        do {
            switch studyGenerationKind {
            case .card:
                let outcome = try await studyService.generateCards(
                    scope: scope, count: studyRequestedCount, chunkBudget: Self.studyChunkBudget)
                studyPreviewCards = outcome.items
                studyOutcomeSummary = Self.studyOutcomeSummary(chunkCount: outcome.chunkCount,
                                                                 succeeded: outcome.succeededChunkCount,
                                                                 invalidCitations: outcome.invalidCitations)
            case .question:
                let outcome = try await studyService.generateQuestions(
                    scope: scope, count: studyRequestedCount, chunkBudget: Self.studyChunkBudget)
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
        } catch {
            studyError = "생성에 실패했습니다: \(error.localizedDescription)"
        }
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
        showStudyHelper = false
    }
}
