import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// 교재 진도 관리 — `StudyProgressView` 배선(레고 2026-08-02 "교재 목차를 가지고 전체 진도
/// 관리"). 계산·파일 형식은 전부 순수 부품(`StudyOutlineExtractor`/`StudyProgressNote`/
/// `StudyProgressCalculator`)에 있고, 이 파일은 화면 상태 + 실제 파일 읽기·쓰기만 잇는다
/// (설계 `docs/superpowers/specs/2026-08-02-study-progress-design.md`).
///
/// **파일 변경은 제안→확인→실행**: 교재 등록은 목차 미리보기를 보여준 뒤 사용자가 "등록"을
/// 눌러야 진도 노트가 생기고, 읽음 체크는 그 앵커 줄 하나만 바꾸며 `.bak` 백업을 1부 남긴다
/// (복습 채점 쓰기와 같은 어법, §3.6).
extension AppState {

    /// 진도 노트를 모아두는 폴더(학습 폴더 밑 "진도").
    func studyProgressFolder() -> URL? {
        guard let base = effectiveStudyFolders().first else { return nil }
        return base.appendingPathComponent(StudyProgressNote.folderName, isDirectory: true)
    }

    // MARK: - 화면 진입 · 목록 읽기

    /// 진도 화면으로 전환(할일 화면과 같은 메인 모드 전환 — 레고 결정 3-b).
    func openStudyProgressView() {
        mainMode = .progress
    }

    /// 등록된 교재 전부를 읽어 진도를 계산한다(진입·재진입 공용).
    @MainActor
    func loadStudyProgress() async {
        studyProgressBusy = true
        studyProgressError = nil
        defer { studyProgressBusy = false }

        guard let folder = studyProgressFolder() else {
            studyProgressBooks = []
            studyProgressSuggestions = []
            studyProgressError = "먼저 설정에서 볼트(노트 폴더)를 정해 주세요."
            return
        }

        var books: [StudyProgressBook] = []
        var registeredSources = Set<String>()
        let fileManager = FileManager.default
        let noteURLs = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        for noteURL in noteURLs {
            guard let content = try? String(contentsOf: noteURL, encoding: .utf8),
                  let parsed = StudyProgressNote.parse(content) else { continue }
            let sourceURL = StudySourceLink.sourceURL(relativePath: parsed.source,
                                                      noteFolder: noteURL.deletingLastPathComponent())
            if let path = sourceURL?.path { registeredSources.insert(path) }
            var indexItems: [StudyIndexItem] = []
            if let path = sourceURL?.path {
                indexItems = await studyIndex.items(forSourcePath: path)
            }
            books.append(StudyProgressBook(
                id: parsed.progressID, noteURL: noteURL, sourceURL: sourceURL,
                sourceKind: parsed.sourceKind,
                sourceExists: sourceURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
                pageOffset: parsed.pageOffset,
                summary: StudyProgressCalculator.summarize(outline: parsed.outline, items: indexItems)))
        }

        studyProgressBooks = books
        if let selected = studyProgressSelectedID, !books.contains(where: { $0.id == selected }) {
            studyProgressSelectedID = books.first?.id
        } else if studyProgressSelectedID == nil {
            studyProgressSelectedID = books.first?.id
        }

        // 카드·문제를 만든 적 있는데 아직 등록 안 된 교재 = 원클릭 등록 후보.
        let known = await studyIndex.distinctSourcePaths()
        studyProgressSuggestions = known
            .filter { !registeredSources.contains($0) && fileManager.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    var selectedStudyProgressBook: StudyProgressBook? {
        guard let id = studyProgressSelectedID else { return nil }
        return studyProgressBooks.first { $0.id == id }
    }

    // MARK: - 교재 등록(제안 → 확인 → 실행)

    /// 교재 파일 고르기 → 목차 미리보기 준비. 이 단계에선 **아무 파일도 만들지 않는다**.
    func pickStudyProgressSource() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .pdf]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        types += DocumentKind.officeExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await prepareStudyProgressOutline(for: url) }
    }

    /// 교재에서 목차를 뽑아 미리보기 상태에 담는다(파일 생성 없음).
    @MainActor
    func prepareStudyProgressOutline(for url: URL) async {
        studyProgressBusy = true
        studyProgressError = nil
        defer { studyProgressBusy = false }

        if studyProgressBooks.contains(where: { $0.sourceURL?.standardizedFileURL == url.standardizedFileURL }) {
            studyProgressError = "이미 등록된 교재입니다."
            return
        }
        guard let extracted = await extractStudyOutline(for: url) else { return }

        studyProgressPendingSource = url
        studyProgressPendingKind = extracted.kind
        studyProgressPendingOutline = extracted.outline
        studyProgressPendingTOC = extracted.tocEntries
        studyProgressPendingOffset = extracted.pageOffset
        studyProgressPendingSourceLabel = extracted.label
    }

    /// 교재 종류별 목차 추출 — 등록·목차 다시 읽기가 함께 쓴다. 실패하면 안내를 남기고 nil.
    @MainActor
    func extractStudyOutline(for url: URL) async
        -> (outline: StudyOutline, kind: DocumentKind, tocEntries: [StudyTOCTextParser.Entry],
            pageOffset: Int, label: String)? {
        guard let kind = Self.studyProgressKind(for: url) else {
            studyProgressError = "이 형식은 진도 관리를 지원하지 않습니다."
            return nil
        }
        switch kind {
        case .pdf:
            guard let result = StudyOutlineExtractor.fromPDF(url: url) else {
                studyProgressError = "PDF를 열지 못했습니다."
                return nil
            }
            return (result.outline, kind, result.tocEntries, result.pageOffset,
                    Self.outlineSourceLabel(result.source))
        case .markdown:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                studyProgressError = "파일을 읽지 못했습니다."
                return nil
            }
            return (StudyOutlineExtractor.fromMarkdown(content: content), kind, [], 0,
                    "글 안의 제목(#)으로 목차를 만들었습니다.")
        case .office:
            guard let body = try? await kordocService.markdown(for: url) else {
                studyProgressError = "문서를 글자로 바꾸지 못했습니다."
                return nil
            }
            return (StudyOutlineExtractor.fromOfficeBody(body), kind, [], 0,
                    "문서의 제목 구간으로 목차를 만들었습니다. 이 형식은 원본 쪽 번호를 알 수 없어 만듦·익힘은 잡히지 않습니다.")
        default:
            studyProgressError = "이 형식은 진도 관리를 지원하지 않습니다."
            return nil
        }
    }

    /// 미리보기 화면에서 쪽번호 보정을 ±로 바꿀 때 — 목차를 그 값으로 다시 조립한다.
    @MainActor
    func setStudyProgressPendingOffset(_ offset: Int) {
        guard !studyProgressPendingTOC.isEmpty,
              let total = studyProgressPendingOutline?.total else { return }
        studyProgressPendingOffset = offset
        studyProgressPendingOutline = StudyOutlineExtractor.outline(
            fromTOCEntries: studyProgressPendingTOC, offset: offset, pageCount: total)
    }

    /// "등록" — 여기서 **처음으로** 진도 노트 파일이 만들어진다.
    @MainActor
    func confirmStudyProgressBook() async {
        guard let outline = studyProgressPendingOutline,
              let sourceURL = studyProgressPendingSource,
              let kind = studyProgressPendingKind,
              let folder = studyProgressFolder() else { return }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let noteURL = Self.uniqueURL(in: folder, fileName: StudyProgressNote.fileName(for: sourceURL))
            let body = StudyProgressNote.build(outline: outline, sourceURL: sourceURL, sourceKind: kind,
                                                noteFolder: folder, pageOffset: studyProgressPendingOffset)
            try body.write(to: noteURL, atomically: true, encoding: .utf8)
            resetStudyProgressPending()
            await loadStudyProgress()
            studyProgressSelectedID = studyProgressBooks.first { $0.noteURL == noteURL }?.id
                ?? studyProgressSelectedID
        } catch {
            studyProgressError = "진도 노트를 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    @MainActor
    func cancelStudyProgressPending() {
        resetStudyProgressPending()
    }

    private func resetStudyProgressPending() {
        studyProgressPendingOutline = nil
        studyProgressPendingSource = nil
        studyProgressPendingKind = nil
        studyProgressPendingTOC = []
        studyProgressPendingOffset = 0
        studyProgressPendingSourceLabel = ""
    }

    // MARK: - 읽음 체크 · 장 추가 · 목차 다시 읽기

    /// 장 하나의 읽음 표시를 바꾼다 — 그 앵커 줄만 치환하고 `.bak` 백업 1부(§3.6과 같은 어법).
    @MainActor
    func toggleStudyProgressRead(bookID: UUID, chapterNo: Int, read: Bool) async {
        guard let book = studyProgressBooks.first(where: { $0.id == bookID }) else { return }
        guard let content = try? String(contentsOf: book.noteURL, encoding: .utf8) else {
            studyProgressError = "진도 노트를 읽지 못했습니다."
            return
        }
        guard let updated = StudyProgressNote.replacingReadFlag(in: content, chapterNo: chapterNo, read: read) else {
            studyProgressError = "이 노트가 그 사이 바뀌었습니다. 화면을 새로고침해 주세요."
            return
        }
        guard writeStudyProgressNote(updated, to: book.noteURL, previous: content) else { return }
        await loadStudyProgress()
    }

    /// 장을 손으로 추가한다(목차 없는 교재 — 레고 결정 2-b).
    @MainActor
    func addStudyProgressChapter(bookID: UUID, title: String, start: Int) async {
        guard let book = studyProgressBooks.first(where: { $0.id == bookID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            studyProgressError = "장 이름을 적어 주세요."
            return
        }
        guard let content = try? String(contentsOf: book.noteURL, encoding: .utf8),
              let parsed = StudyProgressNote.parse(content) else {
            studyProgressError = "진도 노트를 읽지 못했습니다."
            return
        }
        guard start >= 1, start <= parsed.total else {
            studyProgressError = "시작 위치는 1~\(parsed.total) 사이여야 합니다."
            return
        }
        let newOutline = StudyProgressNote.inserting(title: trimmed, start: start, into: parsed.outline)
        guard let updated = StudyProgressNote.replacingOutline(in: content, with: newOutline,
                                                               pageOffset: parsed.pageOffset) else {
            studyProgressError = "목차를 고치지 못했습니다."
            return
        }
        guard writeStudyProgressNote(updated, to: book.noteURL, previous: content) else { return }
        await loadStudyProgress()
    }

    /// 교재에서 목차를 다시 읽어 갈아끼운다(읽음 표시는 장 번호 기준으로 이어받는다).
    @MainActor
    func refreshStudyProgressOutline(bookID: UUID) async {
        guard let book = studyProgressBooks.first(where: { $0.id == bookID }),
              let sourceURL = book.sourceURL, book.sourceExists else {
            studyProgressError = "교재 파일을 찾지 못했습니다(옮겼거나 지웠을 수 있어요)."
            return
        }
        studyProgressBusy = true
        defer { studyProgressBusy = false }

        guard let extracted = await extractStudyOutline(for: sourceURL) else { return }
        let outline = extracted.outline
        let offset = extracted.pageOffset

        guard let content = try? String(contentsOf: book.noteURL, encoding: .utf8),
              let updated = StudyProgressNote.replacingOutline(in: content, with: outline, pageOffset: offset) else {
            studyProgressError = "진도 노트를 고치지 못했습니다."
            return
        }
        guard writeStudyProgressNote(updated, to: book.noteURL, previous: content) else { return }
        await loadStudyProgress()
    }


    // MARK: - 열기

    /// 목차의 장을 눌렀을 때 — 교재의 그 위치를 연다(복습 "원본 보기"와 같은 배선).
    @MainActor
    func openStudyProgressChapter(bookID: UUID, chapter: StudyOutlineChapter) {
        guard let book = studyProgressBooks.first(where: { $0.id == bookID }),
              let sourceURL = book.sourceURL, book.sourceExists else {
            studyProgressError = "교재 파일을 찾지 못했습니다(옮겼거나 지웠을 수 있어요)."
            return
        }
        switch book.summary.unit {
        case .page:
            openDocument(at: sourceURL, inNewTab: true, scrollToPDFPage: chapter.start)
        case .line:
            openDocument(at: sourceURL, inNewTab: true, scrollToLine: chapter.start)
        case .section:
            openDocument(at: sourceURL, inNewTab: true)
        }
    }

    @MainActor
    func openStudyProgressNote(bookID: UUID) {
        guard let book = studyProgressBooks.first(where: { $0.id == bookID }) else { return }
        openDocument(at: book.noteURL, inNewTab: true)
    }

    // MARK: - 도우미

    /// 백업 1부 남기고 덮어쓴다. 실패하면 안내만 하고 false(호출부가 새로고침을 건너뛴다).
    private func writeStudyProgressNote(_ content: String, to url: URL, previous: String) -> Bool {
        do {
            try? previous.write(to: URL(fileURLWithPath: url.path + ".bak"), atomically: true, encoding: .utf8)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            studyProgressError = "저장 실패: \(error.localizedDescription)"
            return false
        }
    }

    static func studyProgressKind(for url: URL) -> DocumentKind? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.pdfExtensions.contains(ext) { return .pdf }
        if DocumentKind.markdownExtensions.contains(ext) { return .markdown }
        if DocumentKind.officeExtensions.contains(ext) { return .office }
        return nil
    }

    static func outlineSourceLabel(_ source: StudyOutlineExtractor.Source) -> String {
        switch source {
        case .embedded:
            return "PDF 안에 들어 있는 목차를 그대로 읽었습니다."
        case .tocText:
            return "목차 페이지에 적힌 차례를 읽었습니다. 쪽 번호가 어긋나면 아래에서 맞춰 주세요."
        case .fallback:
            return "목차를 찾지 못해 전체를 한 덩어리로 두었습니다. 아래에서 장을 직접 더할 수 있습니다."
        }
    }

    /// 같은 이름이 있으면 뒤에 숫자를 붙인다(기존 파일을 덮어쓰지 않는다).
    static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
