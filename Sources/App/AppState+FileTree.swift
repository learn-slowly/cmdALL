import Foundation

extension AppState {

    // MARK: - File Watching

    func startWatchingFile(at url: URL, for tabId: UUID) {
        stopWatchingFile(for: tabId)

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleExternalFileChange(at: url, event: source.data)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileWatchers[tabId] = source
    }

    func stopWatchingFile(for tabId: UUID? = nil) {
        if let tabId = tabId {
            fileWatchers[tabId]?.cancel()
            fileWatchers.removeValue(forKey: tabId)
        } else {
            for watcher in fileWatchers.values {
                watcher.cancel()
            }
            fileWatchers.removeAll()
        }
    }

    func handleExternalFileChange(at url: URL, event: DispatchSource.FileSystemEvent) {
        guard let tab = tabs.first(where: { $0.fileURL == url }) else { return }

        // Atomic saves (Obsidian, vim, VS Code, and most editors) write to a temp
        // file then rename it over the original. That swaps the inode, so the
        // watched fd — bound to the OLD inode — receives .rename/.delete (never
        // .write) and stops seeing changes. So on rename/delete we re-resolve the
        // path and re-arm the watch on the new file, which is why external edits
        // now reflect instead of going silent.
        if event.contains(.rename) || event.contains(.delete) {
            stopWatchingFile(for: tab.id)   // close the stale descriptor
            // Brief delay so the atomic replacement is fully in place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let tab = self.tabs.first(where: { $0.fileURL == url }) else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    self.startWatchingFile(at: url, for: tab.id)   // re-arm on the new inode
                    self.reloadExternally(url: url, tab: tab)
                } else {
                    self.showToast("File was removed externally")
                    if var doc = self.documents[tab.documentId] {
                        doc.fileURL = nil
                        self.documents[tab.documentId] = doc
                    }
                    if let index = self.tabs.firstIndex(where: { $0.id == tab.id }) {
                        self.tabs[index].fileURL = nil
                    }
                }
            }
            return
        }

        if event.contains(.write) || event.contains(.extend) {
            reloadExternally(url: url, tab: tab)
        }
    }

    /// Reloads a tab's content from disk after an external change, preserving the
    /// document's identity (so scroll/selection survive). Won't clobber unsaved
    /// in-app edits — those get a toast prompting a manual reload instead.
    func reloadExternally(url: URL, tab: EditorTab) {
        guard !isTabDirty(tab) else {
            showToast("File changed externally — ⌥⌘R to reload")
            return
        }
        Task { @MainActor in
            do {
                let fresh = try await fileService.loadDocument(from: url)
                if var existing = documents[tab.documentId] {
                    existing.content = fresh.content
                    existing.frontmatter = fresh.frontmatter
                    existing.modifiedAt = Date()
                    documents[tab.documentId] = existing
                    originalContents[tab.documentId] = existing.fullText
                } else {
                    documents[tab.documentId] = fresh
                    originalContents[tab.documentId] = fresh.fullText
                }
                showToast("Reloaded from disk")
            } catch {
                errorMessage = "Failed to reload file: \(error.localizedDescription)"
            }
        }
    }

    func reloadCurrentDocument() {
        guard let url = currentDocument?.fileURL else { return }
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                currentDocument = document
                originalContent = document.fullText
                showToast("Reloaded")
            } catch {
                errorMessage = "Failed to reload: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - File Tree

    func loadFileTree() {
        guard let folder = currentFolder else { return }
        // selectedFolder를 건드리지 않는다(펼치기·새로고침·이름변경 시 호출될 수 있음).
        // 스냅샷을 메인에서 캡처 후 detached 태스크로 파일시스템 탐색(멈춤 방지).
        let snapshot = expandedFolders
        let showHidden = settings.showHiddenFiles
        fileTreeTask?.cancel()
        fileTreeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tree = AppState.buildFileTree(at: folder, expanded: snapshot, showHidden: showHidden)
            guard !Task.isCancelled, let self else { return }
            // 호출 인스턴스에 대입 — static shared 참조 제거(다중 인스턴스·테스트 안전).
            // let 재바인딩으로 Swift 6 'captured var self' 경고 해소.
            await MainActor.run { self.fileTree = tree }
        }
    }

    /// 미리보기 탭을 편집기로 바꾼다(스펙 §4 탈출구).
    /// 맥이 "글자 아님"이라 답했지만 실제로는 글자인 파일(.mdx 등)을 구제한다.
    /// 그 탭이 살아 있는 동안만 유지된다 — 닫았다 열면 다시 미리보기다.
    @MainActor
    func reopenAsText(tabID: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].kind == .quickLook,
              let url = tabs[index].fileURL else { return }
        do {
            let document = try await fileService.loadDocument(from: url)
            // await 뒤에는 탭 배열이 바뀌었을 수 있다 — 인덱스를 다시 찾는다.
            guard let current = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            documents[document.id] = document
            originalContents[document.id] = document.fullText
            tabs[current].documentId = document.id
            tabs[current].kind = .markdown
            tabs[current].title = document.displayTitle
            startWatchingFile(at: url, for: tabID)
            harvestTags(from: document)
        } catch {
            errorMessage = "글로 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 파일 트리·라이브러리에 나열할 파일인가.
    /// 파인더 대체(스펙 §3.5)로 **모든 파일**을 보여준다. 모르는 형식은
    /// DocumentKind가 .quickLook으로 갈라 애플 미리보기로 열리므로 눌러도 깨지지 않는다.
    /// (숨김 파일 제외는 열거 단계의 skipsHiddenFiles가 맡는다 — 여기 책임이 아니다.)
    static func isListableInFileTree(_ url: URL) -> Bool {
        true
    }

    /// 파일트리를 동기·순수하게 빌드한다. `Task.detached`에서 안전히 호출 가능.
    /// - Parameters:
    ///   - url: 탐색 루트 폴더 URL.
    ///   - expanded: 펼친 폴더 스냅샷(메인에서 캡처해 넘긴다).
    ///   - showHidden: 숨김 파일(.으로 시작)을 포함할지 — 기본 false(기존 동작).
    ///   - depth: 재귀 깊이(내부용). depth ≥ 10이면 빈 배열 반환.
    static func buildFileTree(at url: URL, expanded: Set<URL>,
                             showHidden: Bool = false, depth: Int = 0) -> [FileTreeItem] {
        guard depth < 10 else { return [] }

        // F3 정렬용 메타(사용자 결정: 트리도 정렬 적용, 스캔 비용 감수) — 파일 크기·수정일.
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: options
        ) else { return [] }

        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 → 소문자 키(대소문자 무시) — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingKeys = CompanionNote.siblingKeys(contents.map { $0.lastPathComponent })

        for itemURL in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let resourceValues = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            let modifiedAt = resourceValues.contentModificationDate

            if isDirectory {
                let isExpanded = expanded.contains(itemURL)
                let children = isExpanded ? buildFileTree(at: itemURL, expanded: expanded,
                                                          showHidden: showHidden, depth: depth + 1) : []
                items.append(FileTreeItem(url: itemURL, isDirectory: true, isExpanded: isExpanded,
                                          children: children, modifiedAt: modifiedAt))
            } else {
                if isListableInFileTree(itemURL) {
                    // 짝꿍 노트는 목록에서 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                    if CompanionNote.isCompanionNote(itemURL, siblingKeys: siblingKeys) { continue }
                    let hasNote = CompanionNote.hasCompanionNote(for: itemURL, siblingKeys: siblingKeys)
                    items.append(FileTreeItem(url: itemURL, isDirectory: false, hasCompanionNote: hasNote,
                                              fileSize: resourceValues.fileSize.map(Int64.init),
                                              modifiedAt: modifiedAt))
                }
            }
        }

        return items.sorted { item1, item2 in
            if item1.isDirectory == item2.isDirectory {
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            }
            return item1.isDirectory && !item2.isDirectory
        }
    }

    func toggleFolderExpansion(_ url: URL) {
        if expandedFolders.contains(url) {
            expandedFolders.remove(url)
        } else {
            expandedFolders.insert(url)
        }
        loadFileTree()
    }

    /// 스프링로딩용 펼침 — insert 전용 멱등(스펙 §5). 기존 toggle은 드래그 오버
    /// 재발화 시 도로 접히는 비멱등이라 드래그 경로에 부적합.
    func expandFolder(_ url: URL) {
        guard !expandedFolders.contains(url) else { return }
        expandedFolders.insert(url)
        loadFileTree()
    }

    /// Creates a new, uniquely-named Markdown file in `folder` and opens it.
    /// (The old implementation blindly wrote an empty "Untitled.md", silently
    /// truncating an existing file of that name.)
    func createNewFile(in folder: URL) {
        let target = folder.appendingPathComponent("Untitled.md").uniquified()
        do {
            try "".write(to: target, atomically: true, encoding: .utf8)
            loadFileTree()
            openDocument(at: target, inNewTab: true)
            viewMode = .source
        } catch {
            errorMessage = "Failed to create file: \(error.localizedDescription)"
        }
    }

    /// parent 안에 새 폴더 생성 — FileOperations 위임(기본 이름 "새 폴더"·uniquify).
    /// 새 폴더는 작업 로그에 기록하지 않는다(되돌리기=삭제라 정책 충돌 — 스펙 §2).
    func createNewFolder(in parent: URL) {
        do {
            _ = try FileOperations.createFolder(in: parent)
            fileOpsGeneration += 1
            loadFileTree()
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
