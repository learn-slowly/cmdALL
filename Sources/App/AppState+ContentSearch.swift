import Foundation
import PDFKit

extension AppState {

    // MARK: - Completion Index

    /// Rebuilds the wiki-link completion index off the main thread. Scans the
    /// open folder, registered vault roots, and registered content-search
    /// folders(설정 화면 "검색 인덱스" 목록 — 2026-07-29 발견: 이 셋이 따로 놀아서
    /// 문서/다운로드처럼 열려있지도 vault도 아닌 등록 폴더는 파일명 검색(Files 섹션)에
    /// 안 걸리고 내용검색(In-file Matches)에서만 잡히던 어긋남을 통합) for note files
    /// (names only — file contents are never read here).
    func rebuildNoteIndex() {
        noteIndexTask?.cancel()
        var roots: [URL] = []
        if let currentFolder { roots.append(currentFolder) }
        roots.append(contentsOf: vaults.map(\.rootPath))
        roots.append(contentsOf: settings.indexedFolders.map { URL(fileURLWithPath: $0) })

        guard !roots.isEmpty else {
            linkableNotes = []
            return
        }

        // Hop back through the static ref instead of capturing self across the
        // detached-task boundary (AppState itself is not Sendable).
        noteIndexTask = Task.detached(priority: .utility) {
            let notes = NoteIndexService.buildIndex(roots: roots) { chunk in
                // onChunk는 이 detached task 실행 흐름 안에서 동기 호출되므로,
                // 여기서 보는 Task.isCancelled는 바깥 noteIndexTask 자신의 취소 상태다.
                guard !Task.isCancelled else { return }
                Task { @MainActor in
                    AppState.shared?.linkableNotes = chunk
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AppState.shared?.linkableNotes = notes
            }
        }
    }

    /// Collects tags from a document (frontmatter + inline #tags) so the tag
    /// completion popup learns vocabulary from everything the user opens.
    func harvestTags(from document: MarkdownDocument) {
        var tags = Set(document.frontmatter?.tags ?? [])
        let ns = document.content as NSString
        Self.inlineTagPattern.enumerateMatches(in: document.content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            tags.insert(ns.substring(with: match.range(at: 1)))
        }
        knownTags.formUnion(tags)
    }

    // MARK: - 내용 검색(인덱스)

    /// 등록 폴더 목록 정규화: 중복·기존 하위 추가는 무시하고, 새 상위가 기존 하위를 흡수한다.
    /// 경로는 표준화 후 접두 비교("/a"는 "/a/"로 보고 "/a/sub"를 하위로 본다).
    static func normalizedIndexFolders(_ existing: [String], adding: String) -> [String] {
        func norm(_ p: String) -> String { (p as NSString).standardizingPath }
        let add = norm(adding)
        func isAncestor(_ anc: String, _ desc: String) -> Bool {
            desc == anc || desc.hasPrefix(anc.hasSuffix("/") ? anc : anc + "/")
        }
        // 이미 등록됐거나 기존 항목의 하위면 변화 없음.
        for e in existing where isAncestor(norm(e), add) { return existing }
        // 새 항목의 하위인 기존 항목들을 제거(흡수)하고 새 항목 추가.
        var kept = existing.filter { !isAncestor(add, norm($0)) }
        // standardizingPath는 /private 접두를 떼므로 비교에만 쓰고, 저장은 호출자가 넘긴 canonical 경로 그대로 둔다.
        kept.append(adding)
        return kept
    }

    /// 폴더를 등록 목록에 정규화 추가하고 인덱싱·감시를 시작한다.
    @MainActor
    func registerIndexFolder(_ url: URL) {
        let canonical = SearchIndexer.canonicalURL(url)
        let next = Self.normalizedIndexFolders(settings.indexedFolders, adding: canonical.path)
        guard next != settings.indexedFolders else { return }
        settings.indexedFolders = next
        saveUserData()
        startFolderWatching()
        rebuildNoteIndex()   // 파일명 검색(Files 섹션) 범위도 즉시 넓힌다.
        reindexFolder(canonical.path)
    }

    /// 등록 해제: 목록에서 빼고 인덱스에서 그 하위를 제거한다(디스크 파일은 불변).
    @MainActor
    func unregisterIndexFolder(_ path: String) {
        let canonicalPath = SearchIndexer.canonicalURL(URL(fileURLWithPath: path)).path
        settings.indexedFolders.removeAll { $0 == canonicalPath || $0 == path }
        saveUserData()
        startFolderWatching()
        rebuildNoteIndex()   // 뺀 폴더는 파일명 검색에서도 즉시 빠지게.
        Task { _ = await searchIndex.removeUnder(folder: canonicalPath) }
    }

    /// 인덱스 DB가 스키마 변경으로 재구성됐거나 추출 규칙이 바뀌었으면 등록된 모든 폴더를 재인덱싱한다.
    @MainActor
    func reindexAfterSchemaMigration() async {
        let schemaChanged = await searchIndex.didResetForSchemaChange
        // 추출 규칙이 넓어져도 파일 수정 시각은 그대로라 needsIndex만으로는 갱신되지
        // 않는다 → 판 번호로 한 번 다시 훑는다(스펙 §3.6).
        let extractorChanged = await searchIndex.storedExtractorVersion < SearchIndex.currentExtractorVersion
        guard schemaChanged || extractorChanged else { return }
        // 예전에 적어둔 mtime이 남아 있으면 다시 훑어도 needsIndex가 그대로 건너뛰어
        // 넓어진 규칙이 반영 안 된다 → 비우고 처음부터 다시 채운다(스키마 재구성
        // 경로는 이미 비어 있어 무해한 재확인일 뿐).
        await searchIndex.clear()
        // reindexFolder(fire-and-forget)가 아니라 searchIndexer를 직접 기다린다 —
        // 판 번호를 실제 완주 전에 적으면, 중간에 종료됐을 때 다음 실행이 "이미
        // 끝났다"고 오판해 다시 훑지 않는다(판 번호 도입 취지 자체가 무력화됨).
        for folder in settings.indexedFolders {
            await searchIndexer.indexFolder(URL(fileURLWithPath: folder), ocrScannedPDFs: settings.ocrScannedPDFsEnabled, ocrImages: settings.ocrImagesEnabled, progress: nil)
        }
        await searchIndex.setExtractorVersion(SearchIndex.currentExtractorVersion)
    }

    /// 한 폴더를 (재)인덱싱한다(진행률 표시).
    @MainActor
    func reindexFolder(_ path: String) {
        indexInProgress = true
        indexProgress = (0, 0)
        Task {
            await searchIndexer.indexFolder(URL(fileURLWithPath: path), ocrScannedPDFs: settings.ocrScannedPDFsEnabled, ocrImages: settings.ocrImagesEnabled) { done, total in
                Task { @MainActor in self.indexProgress = (done, total) }
            }
            await MainActor.run {
                self.indexInProgress = false
                self.indexProgress = nil
            }
        }
    }

    /// 자료에 묻기(RAG) 실행. 근거 없으면 안내, 성공하면 답변+출처를 채운다.
    @MainActor
    func runRagQuery() async {
        let q = ragQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !ragBusy else { return }   // 빈 질문·중복 실행 방지
        ragBusy = true
        defer { ragBusy = false }
        ragAnswer = nil
        ragSources = []
        ragMessage = nil
        let outcome = await ragService.ask(question: q, expandQuery: settings.ragExpandQuery)
        switch outcome {
        case .answered(let a):
            ragAnswer = a.text
            ragSources = a.sources
        case .noEvidence:
            ragMessage = "자료에서 관련 내용을 찾지 못했습니다."
        case .failed(let e):
            ragMessage = AppState.aiErrorMessage(e, provider: settings.aiProvider)
        }
    }

    /// 근거 출처를 그 위치(줄/페이지)로 연다.
    @MainActor
    func openRagSource(_ source: RagSource) {
        showAskCorpus = false
        let url = URL(fileURLWithPath: source.path)
        switch source.location {
        case .line(let n): openDocument(at: url, inNewTab: true, scrollToLine: n)
        case .page(let p): openDocument(at: url, inNewTab: true, scrollToPDFPage: p)
        case .unknown: openDocument(at: url, inNewTab: true)
        }
    }

    /// 등록 폴더로 파일 감시를 (재)시작한다. 변경 경로를 증분 재인덱싱.
    @MainActor
    func startFolderWatching() {
        folderWatcher.onChangedPaths = { [weak self] paths in
            guard let self else { return }
            Task { @MainActor in
                for p in Set(paths) {
                    await self.searchIndexer.reindex(path: p, ocrScannedPDFs: self.settings.ocrScannedPDFsEnabled, ocrImages: self.settings.ocrImagesEnabled)
                }
            }
        }
        folderWatcher.start(folders: settings.indexedFolders)
    }

    // MARK: - Folder Search

    func searchInFolder(query: String) {
        // 새 검색을 시작하기 전 이전 검색 Task를 취소한다(느린 변환이 늦게 끝나
        // 낡은 결과로 현재 검색어 결과를 덮어쓰는 정합성 버그 방지).
        folderSearchTask?.cancel()
        guard let folder = currentFolder, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchResults = []

        folderSearchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.performSearch(query: query, in: folder)
            if Task.isCancelled { return }
            await MainActor.run {
                // 결과가 늦게 와도 그 사이 검색어가 바뀌었으면 덮어쓰지 않음.
                guard self.folderSearchText == query else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    /// 파일명에 query(대소문자 무시)가 들어있으면 .filename 결과를 만든다.
    static func filenameMatch(_ url: URL, query: String) -> SearchResult? {
        guard !query.isEmpty else { return nil }
        let name = url.lastPathComponent
        guard let range = name.range(of: query, options: .caseInsensitive) else { return nil }
        return SearchResult(fileURL: url, lineNumber: 0, lineContent: name,
                            matchRange: range, kind: .filename)
    }

    /// text의 각 줄에서 query(대소문자 무시) 첫 위치를 찾아 .line 결과(줄번호 1-base)로.
    static func contentLineMatches(in text: String, fileURL: URL, query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [SearchResult] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if let range = line.range(of: query, options: .caseInsensitive) {
                results.append(SearchResult(fileURL: fileURL, lineNumber: index + 1,
                                            lineContent: line, matchRange: range, kind: .line))
            }
        }
        return results
    }

    func performSearch(query: String, in folder: URL,
                              includeFilenames: Bool = true,
                              includePDFBody: Bool = true,
                              includeOfficeBody: Bool = true) async -> [SearchResult] {
        var results: [SearchResult] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let maxResults = 500
        let textExtensions: Set<String> = ["md", "markdown", "txt"]

        // Pull all URLs up front: iterating an enumerator directly is a
        // makeIterator call that's unavailable from async contexts in Swift 6.
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }

        for fileURL in fileURLs {
            if Task.isCancelled { return results }
            guard Self.isListableInFileTree(fileURL) else { continue }

            // 1) 파일명 매칭(모든 종류: md/txt·이미지·pdf) — Omnisearch는 끔
            if includeFilenames, let nameHit = Self.filenameMatch(fileURL, query: query) {
                results.append(nameHit)
                if results.count >= maxResults { return results }
            }

            let ext = fileURL.pathExtension.lowercased()

            // 2) 텍스트 본문(md/markdown/txt)
            if textExtensions.contains(ext) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    for hit in Self.contentLineMatches(in: content, fileURL: fileURL, query: query) {
                        results.append(hit)
                        if results.count >= maxResults { return results }
                    }
                }
            // 3) PDF 본문(페이지별 추출 → .pdfPage) — Omnisearch는 끔(실시간 추출 방지)
            } else if includePDFBody, DocumentKind.pdfExtensions.contains(ext) {
                if let pdf = PDFDocument(url: fileURL) {
                    for pageIndex in 0..<pdf.pageCount {
                        if Task.isCancelled { return results }
                        guard let page = pdf.page(at: pageIndex),
                              let pageText = page.string else { continue }
                        for hit in Self.contentLineMatches(in: pageText, fileURL: fileURL, query: query) {
                            results.append(SearchResult(
                                fileURL: fileURL,
                                lineNumber: pageIndex + 1,        // 페이지 번호(1-base)
                                lineContent: hit.lineContent,
                                matchRange: hit.matchRange,
                                kind: .pdfPage
                            ))
                            if results.count >= maxResults { return results }
                        }
                    }
                }
            // 4) 오피스 본문(kordoc → 마크다운 → 줄 매칭 → .officeBody) — Omnisearch는 끔(변환 방지)
            } else if includeOfficeBody, DocumentKind.officeExtensions.contains(ext) {
                if let md = try? await kordocService.markdown(for: fileURL) {
                    for hit in Self.contentLineMatches(in: md, fileURL: fileURL, query: query) {
                        results.append(SearchResult(
                            fileURL: fileURL,
                            lineNumber: hit.lineNumber,
                            lineContent: hit.lineContent,
                            matchRange: hit.matchRange,
                            kind: .officeBody
                        ))
                        if results.count >= maxResults { return results }
                    }
                }
            }
            // 이미지: 본문 없음 — 파일명 매칭만(위 1번)
        }

        return results
    }

    func clearSearch() {
        folderSearchText = ""
        searchResults = []
        isSearching = false
    }

    /// Omnisearch의 내용(In-file) 검색 — 이미 자동으로 훑어둔 색인(FTS5)에서 가져온다.
    /// pdf·hwp·워드·엑셀 안 내용도 포함(색인이 이미 커버, §방법2로 실시간 스캔 방식 폐기).
    func searchContent(query: String) async -> [IndexHit] {
        guard !query.isEmpty else { return [] }
        return await searchIndex.search(query: query, limit: 12)
    }
}
