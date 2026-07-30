import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {

    // MARK: - Opening Files

    func openFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, UTType(filenameExtension: "md")!,
                               .png, .jpeg, .heic, .webP, .gif, .pdf]
        types += DocumentKind.officeExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            for url in panel.urls {
                openDocument(at: url, inNewTab: true)
            }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(at: url)
        }
    }

    /// 작업 폴더를 지정 URL로 전환한다 — File > Open Folder의 성공 분기와 동일.
    /// 즐겨찾기 폴더 열기 등 패널 없는 진입로가 재사용한다.
    /// - Parameter autoIndex: 이 폴더를 내용 검색 색인에도 자동 등록할지. 기본 true(File
    ///   메뉴로 직접 연 폴더·즐겨찾기 등 "의도한 작업 폴더"). 사이드바 기본 위치(홈·데스크탑·
    ///   다운로드·문서)처럼 그냥 훑어보기용 바로가기는 false로 호출한다 — 다운로드 폴더 전체가
    ///   클릭 한 번에 몇만 개짜리 내용 색인 작업으로 둔갑하는 것을 막는다(2026-07-27 실사용 발견).
    func openFolder(at url: URL, autoIndex: Bool = true) {
        currentFolder = url
        // currentFolder가 실제로 바뀌는 지점에서만 selectedFolder를 리셋한다.
        selectedFolder = url
        selectedSidebarTab = .files
        sidebarVisible = true
        loadFileTree()
        rebuildNoteIndex()
        if autoIndex {
            Task { @MainActor in self.registerIndexFolder(url) }   // 열면 자동으로 내용(pdf·오피스 포함)까지 뒤에서 훑는다.
        }
        saveSession()
    }

    /// 사이드바 폴더 행 탭 시 라이브러리 모드로 전환하고 표시 폴더를 설정한다.
    func selectFolderForLibrary(_ url: URL) {
        selectedFolder = url
        mainMode = .library
    }

    // MARK: - 뒤로/앞으로/상위 (F3)

    func recordNavigationIfNeeded() {
        guard !suppressHistoryRecording, let root = currentFolder else { return }
        navHistory.record(FolderLocation(root: root, display: selectedFolder ?? root))
    }

    /// 히스토리 항목의 두 폴더가 모두 디렉터리로 실존하는가.
    static func folderExists(_ loc: FolderLocation) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: loc.root.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        guard FileManager.default.fileExists(atPath: loc.display.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return true
    }

    func goBackInHistory() {
        guard let loc = navHistory.goBack(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    func goForwardInHistory() {
        guard let loc = navHistory.goForward(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    /// 히스토리 항목 적용 — 루트가 다르면 openFolder 경로 재사용(트리·인덱스·세션까지 복원).
    /// 항상 라이브러리 모드로 전환 — 리더에 남아 화면이 안 바뀌는 함정 방지(스펙 §3.2).
    func applyHistoryLocation(_ loc: FolderLocation) {
        suppressHistoryRecording = true
        defer { suppressHistoryRecording = false }
        if currentFolder?.standardizedFileURL.path != loc.root.standardizedFileURL.path {
            openFolder(at: loc.root, autoIndex: false)   // 뒤로/앞으로는 탐색이지 새 폴더 선택이 아니다.
        }
        selectedFolder = loc.display
        mainMode = .library
    }

    /// 라이브러리 표시 폴더 기준 상위 이동 가능 여부 — currentFolder(루트) 하한.
    /// (LibraryView에서 이전 — 메뉴·⌘↑가 호출할 수 있게 AppState 소유, 스펙 §6)
    var canGoUpInLibrary: Bool {
        guard let display = selectedFolder ?? currentFolder,
              let root = currentFolder else { return false }
        let displayStd = display.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        // '/' 경계를 포함해 형제 폴더 오감지를 방지한다.
        return displayStd != rootStd && displayStd.hasPrefix(rootStd + "/")
    }

    /// 상위 폴더로(⌘↑·메뉴·경로 바) — 라이브러리 모드에서만(리더의 NSTextView ⌘↑ 표준
    /// 동작 강탈 방지, 스펙 §6), root 하한 클램프.
    func goUpInLibrary() {
        guard mainMode == .library else { return }
        guard let current = selectedFolder ?? currentFolder,
              let root = currentFolder else { return }
        let parent = current.deletingLastPathComponent()
        let parentStd = parent.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        if parentStd == rootStd || parentStd.hasPrefix(rootStd + "/") {
            selectedFolder = parent
        }
    }

    /// View 메뉴 ⌘↑ 전용 진입점 — 텍스트 입력 포커스(시트 필드·사이드바 검색 등)의 캐럿 이동
    /// (macOS 표준 ⌘↑)을 강탈하지 않도록 responder를 확인한다(F1b ⌘C 가드 동형).
    /// 커맨드 팔레트는 goUpInLibrary()를 직접 호출한다 — dismiss 직후 동기 실행이라
    /// firstResponder가 아직 팔레트 필드일 수 있어 이 가드를 태우면 팔레트 진입점이 죽는다.
    func goUpInLibraryFromMenu(firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder) {
        if Self.responderYieldsFileKeys(firstResponder) { return }
        goUpInLibrary()
    }

    /// 표시 중 폴더가 rename/trash로 사라졌으면 가장 가까운 존재 조상으로 재조준
    /// (F1a 트리아지 잔여 — 빈 라이브러리·죽은 경로 바 방지, 스펙 §5).
    /// 사용자 내비게이션이 아니므로 히스토리에 기록하지 않는다. internal = 테스트 접근용.
    func retargetStaleSelectedFolder() {
        guard let sel = selectedFolder else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir), isDir.boolValue { return }
        var candidate = sel.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue { break }
            candidate = candidate.deletingLastPathComponent()
        }
        suppressHistoryRecording = true
        selectedFolder = candidate
        suppressHistoryRecording = false
    }

    // MARK: - 폴더별 기억 (레이아웃 Phase 8.5-③ · 정렬 F3)

    /// 폴더별 기억(레이아웃·정렬) 딕셔너리 키 — 두 기능이 같은 규약을 쓴다.
    /// 심링크(/var↔/private/var)까지는 해소하지 않는다(libraryLayouts·F1b 관례, 스펙 §2.3).
    static func folderMemoryKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 폴더별 기억의 기준 폴더 — 복원·저장이 같은 폴백을 쓴다(기존 restore가
    /// selectedFolder만 보던 비대칭 해소, 스펙 §2.3).
    var folderMemoryTarget: URL? { selectedFolder ?? currentFolder }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 레이아웃을 복원한다.
    /// 기억이 없으면 현재 레이아웃을 그대로 유지한다.
    func restoreLibraryLayoutForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        guard let remembered = settings.libraryLayouts[Self.folderMemoryKey(for: url)] else { return }
        guard remembered != libraryLayout else { return }
        isRestoringLayout = true
        libraryLayout = remembered
        isRestoringLayout = false
    }

    /// libraryLayout이 바뀔 때 현재 폴더에 레이아웃을 기억하고 즉시 영속한다.
    func persistLibraryLayoutForCurrentFolder(oldValue: LibraryLayout) {
        guard !isRestoringLayout else { return }
        guard oldValue != libraryLayout else { return }
        guard let url = folderMemoryTarget else { return }
        settings.libraryLayouts[Self.folderMemoryKey(for: url)] = libraryLayout
        saveUserData()
    }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 정렬을 복원한다.
    /// 레이아웃과 달리 기억이 없으면 **기본(PARA)으로 복귀**한다 — 정렬은 폴더 속성(스펙 §2.3).
    func restoreLibrarySortForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        let remembered = settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
        guard remembered != librarySort else { return }
        isRestoringSort = true
        librarySort = remembered
        isRestoringSort = false
    }

    /// librarySort가 바뀔 때 현재 폴더에 정렬을 기억하고 즉시 영속한다.
    func persistLibrarySortForCurrentFolder(oldValue: LibrarySort) {
        guard !isRestoringSort else { return }
        guard oldValue != librarySort else { return }
        guard let url = folderMemoryTarget else { return }
        settings.librarySorts[Self.folderMemoryKey(for: url)] = librarySort
        saveUserData()
    }

    /// 임의 폴더의 기억된 정렬(없으면 PARA 기본) — 사이드바 트리가 폴더별 렌더 정렬에 사용(스펙 §2.5).
    func sortForFolder(_ url: URL?) -> LibrarySort {
        guard let url else { return .default }
        return settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
    }

    func openInternalURL(_ url: URL) {
        guard url.scheme == "cmdmd" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let note = components.queryItems?.first(where: { $0.name == "note" })?.value {
                openLinkedNote(note)
                return
            }

            if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                openDocument(at: URL(fileURLWithPath: path))
                return
            }
        }

        if url.host == "open", let path = url.pathComponents.dropFirst().first {
            openDocument(at: URL(fileURLWithPath: path))
        }
    }

    func openLinkedNote(_ rawTarget: String) {
        guard let target = LinkedNoteResolver.normalizedTarget(rawTarget) else { return }

        let roots = linkedNoteSearchRoots()
        let resolver = LinkedNoteResolver(roots: roots)

        if let directURL = resolver.resolveDirectCandidate(named: target) {
            openDocument(at: directURL, inNewTab: true)
            return
        }

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                LinkedNoteResolver(roots: roots).resolve(normalizedTarget: target)
            }.value

            await MainActor.run {
                if let found {
                    self.openDocument(at: found, inNewTab: true)
                } else {
                    self.showToast("Linked note not found: \(target)")
                }
            }
        }
    }

    func openDocument(at url: URL, inNewTab: Bool = false,
                      scrollToLine line: Int? = nil, scrollToPDFPage pdfPage: Int? = nil) {
        mainMode = .reader
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            if let line {
                // media 탭(짝꿍 노트 리다이렉트 등)은 알림 구독자가 없어 줄 정보가 소실된다.
                // 탭별 pending으로 담아뒀다가 MediaReaderView가 노트 로드 후 소비한다.
                if existingTab.kind == .media {
                    pendingMediaScrollLines[existingTab.id] = line
                } else {
                    scrollEditor(toLine: line)
                }
            }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
            return
        }

        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line {
                // 로드 분기 — 짝꿍 노트를 열었다가 media로 리다이렉트된 경우도 포함.
                if currentTabKind == .media, let id = activeTabId {
                    pendingMediaScrollLines[id] = line
                } else {
                    scrollEditor(toLine: line)
                }
            }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
        }
    }

    /// PDF 탭이 떠서 PDFReaderView가 구독을 마칠 시간을 준 뒤 페이지 점프 노티 게시.
    func scrollPDF(toPage page: Int, url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .scrollToPDFPage,
                                            object: PDFPageJump(url: url, page: page))
        }
    }

    /// 외부에서 온 파일 열기 요청을 직렬 큐에 제출한다 — 항상 새 탭(같은 URL은 기존 탭 활성,
    /// 스펙 §2.2). 배치 안 순서 = 열리는 순서, 마지막 파일이 활성.
    func enqueueExternalOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let prev = externalOpenChain
        externalOpenChain = Task { @MainActor in
            await prev?.value
            self.mainMode = .reader
            for url in urls {
                await self.loadAndActivateDocument(at: url, inNewTab: true)
            }
            self.presentMainWindowIfNeeded()
        }
    }

    /// AppKit `application(_:open:)`가 받은 URL 배열을 분류·라우팅한다 — cmdmd 스킴은
    /// 내부 열기, 파일은 외부 열기 직렬 큐로. 단일 Window 씬에선 배치 열기(Finder 다중
    /// 선택)가 `.onOpenURL`에 첫 URL만 전달되는 실측 한계가 있어(WindowGroup은 URL마다
    /// 씬을 만들어 개별 발화했음), 전체 배열을 받는 델리게이트 경로가 정경로다.
    static func routeOpenedURLs(_ urls: [URL], to appState: AppState?) {
        guard let appState else { return }
        var files: [URL] = []
        for url in urls {
            if url.scheme == "cmdmd" {
                appState.openInternalURL(url)
            } else if url.isFileURL {
                files.append(url)
            }
        }
        appState.enqueueExternalOpen(files)
    }

    /// 외부 열기 처리 후 문서 창을 앞으로 가져온다(닫혀 있으면 재표시). 단일 Window 씬은
    /// WindowGroup과 달리 이벤트 전달용 새 창을 만들지 않으므로 필요(스펙 §2.1).
    /// 닫힌(ordered-out) 창은 canBecomeMain이 항상 false라(최종 리뷰 프로브 실측) 그 조건으로는
    /// 못 찾는다 — Window(id: "main")가 NSWindow.identifier에 남기는 접두사로 우선 판별하고,
    /// (보이는 창용) canBecomeMain 폴백을 둔다. headless 테스트에선 NSApp이 nil이라 no-op.
    func presentMainWindowIfNeeded() {
        guard let app = NSApp else { return }
        app.activate(ignoringOtherApps: true)
        let main = app.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? app.windows.first(where: { $0.canBecomeMain })
        main?.makeKeyAndOrderFront(nil)
    }

    /// 새 탭을 추가하거나 활성 탭을 교체(교체 시 옛 탭 자원 정리).
    func placeTab(_ tab: EditorTab, inNewTab: Bool) {
        if inNewTab || tabs.isEmpty {
            tabs.append(tab)
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }) {
            let oldTab = tabs[activeIndex]
            stopWatchingFile(for: oldTab.id)
            documents.removeValue(forKey: oldTab.documentId)
            originalContents.removeValue(forKey: oldTab.documentId)
            officeStates.removeValue(forKey: oldTab.id)
            officeOriginalRenderStates.removeValue(forKey: oldTab.id)
            // 탭 id는 재사용되지 않으므로 여기서 안 지우면 플레이어가 영구 잔류(누수)한다.
            mediaPlayers.removeValue(forKey: oldTab.id)?.pause()
            tabs[activeIndex] = tab
        } else {
            tabs.append(tab)
        }
        activeTabId = tab.id
    }

    /// 짝꿍 노트 URL이면 대응 미디어 URL을 반환(미디어 실재 시). 아니면 nil.
    /// 검색·위키링크 등 모든 열기 진입로에서 노트 대신 미디어 뷰를 열기 위한 판별원.
    static func mediaRedirectTarget(for url: URL) -> URL? {
        guard let mediaURL = CompanionNote.mediaURL(for: url),
              FileManager.default.fileExists(atPath: mediaURL.path) else { return nil }
        return mediaURL
    }

    @MainActor
    func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        // 짝꿍 노트를 직접 열면 대응 미디어로 리다이렉트 — 노트는 미디어 뷰 안에서 열람·편집한다.
        let target = Self.mediaRedirectTarget(for: url) ?? url
        if let existingTab = tabs.first(where: { $0.fileURL == target }) {
            activeTabId = existingTab.id
            return
        }
        guard let tab = await loadDocument(at: target) else { return }
        placeTab(tab, inNewTab: inNewTab)
        finishOpening(tab)
        saveSession()
    }

    /// 문서를 읽어 "미배치" 탭을 만든다 — placeTab/활성화/saveSession 없음(스펙 §2.4).
    /// 리다이렉트·중복 판별은 호출자 몫. markdown 로드 실패 시 errorMessage 세팅 후 nil.
    @MainActor
    func loadDocument(at url: URL) async -> EditorTab? {
        // 이미지·PDF·오피스·미디어: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind != .markdown {
            return EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
        }
        do {
            let document = try await fileService.loadDocument(from: url)
            let tab = EditorTab(
                documentId: document.id,
                fileURL: url,
                title: document.displayTitle
            )
            documents[document.id] = document
            originalContents[document.id] = document.fullText
            return tab
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
            return nil
        }
    }

    /// 열기 마무리 부수효과(최근 파일·오피스 변환 재시도·파일 워처·태그 수확) —
    /// 단건(loadAndActivateDocument)·배치(restoreSessionIfNeeded) 공용.
    @MainActor
    func finishOpening(_ tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        addToRecentFiles(url)
        switch tab.kind {
        case .office:
            retryOfficeConversion(tabID: tab.id, fileURL: url)
        case .markdown:
            startWatchingFile(at: url, for: tab.id)
            if let document = documents[tab.documentId] {
                harvestTags(from: document)
            }
        default:
            break
        }
    }

    /// Posts the scroll request after a short delay so a freshly-created editor
    /// (the editor subtree is keyed to document identity) has time to subscribe.
    func scrollEditor(toLine line: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NotificationCenter.default.post(name: .scrollToLine, object: line)
            guard let self, self.viewMode != .source else { return }
            // In preview/split, also bring the nearest preceding heading into view.
            if let slug = self.nearestHeadingSlug(before: line) {
                NotificationCenter.default.post(name: .scrollToHeading, object: slug)
            }
        }
    }

    func nearestHeadingSlug(before line: Int) -> String? {
        Self.nearestHeadingSlug(in: currentDocument?.content ?? "", before: line)
    }

    /// 주어진 줄 앞에서 가장 가까운 헤딩의 slug. 순수 함수 — media 짝꿍 노트처럼
    /// currentDocument가 없는 콘텐츠(문자열만 있는 경우)에서도 쓸 수 있도록 분리.
    static func nearestHeadingSlug(in content: String, before line: Int) -> String? {
        let headings = TOCBuilder.extractHeadings(from: content)
        return headings.last(where: { $0.lineNumber <= line })?.slug
    }

    func linkedNoteSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let documentFolder = currentDocument?.fileURL?.deletingLastPathComponent() {
            roots.append(documentFolder)
        }
        if let currentFolder {
            roots.append(currentFolder)
        }
        roots.append(contentsOf: vaults.map(\.rootPath))

        var seen: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}
