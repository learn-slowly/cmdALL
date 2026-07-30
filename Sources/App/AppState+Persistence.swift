import Foundation

extension AppState {

    // MARK: - Session Persistence

    var sessionURL: URL { dataURL.appendingPathComponent("session.json") }

    func saveSession() {
        let openFiles = tabs.compactMap(\.fileURL)
        var activeIndex: Int?
        if let activeURL = activeTab?.fileURL {
            activeIndex = openFiles.firstIndex(of: activeURL)
        }
        let session = SessionState(
            openFiles: openFiles,
            activeFileIndex: activeIndex,
            viewMode: viewMode,
            currentFolder: currentFolder,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            try? data.write(to: sessionURL)
        }
    }

    /// 콜드런치 세션 복원의 마지막 활성 탭 재지정 여부를 판정한다. 순수 함수 — 복원 루프가
    /// 파일들을 순차 로드하는 동안 Finder 더블클릭(`onOpenURL`) 같은 외부 열기가 끼어들어
    /// activeTabId를 이미 다른 탭으로 옮겼다면, 복원 마지막 줄이 그걸 덮어쓰지 않도록 막는다.
    /// current가 nil이거나 복원 루프가 만든/연 탭 중 하나면 재지정을 허용한다.
    static func shouldRestoreActiveTab(current: UUID?, restoredTabIds: Set<UUID>) -> Bool {
        guard let current else { return true }
        return restoredTabIds.contains(current)
    }

    func restoreSessionIfNeeded() {
        guard settings.restoreLastSession,
              let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionState.self, from: data) else { return }

        viewMode = session.viewMode
        sidebarVisible = session.sidebarVisible
        inspectorVisible = session.inspectorVisible

        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            suppressHistoryRecording = true
            currentFolder = folder
            // 세션 복원 시 currentFolder가 바뀌므로 selectedFolder도 리셋한다.
            selectedFolder = folder
            suppressHistoryRecording = false
            // 복원 위치를 히스토리 시작점으로 seed(가짜 뒤로 항목 없이).
            navHistory.record(FolderLocation(root: folder, display: folder))
            loadFileTree()
            Task { @MainActor in self.registerIndexFolder(folder) }   // 복원한 폴더도 자동으로 내용까지 훑는다.
        }

        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        // 배치 복원(스펙 §2.4) — 로드만 하고 일괄 append, 활성 탭은 끝에 정확히 1회.
        // 이 Task를 외부 열기 큐 선두에 시드해, 복원 중 도착한 외부 열기(onOpenURL·드롭)는
        // 체인상 복원 뒤에 처리된다 → 자연히 "외부 파일 = 마지막 = 활성".
        externalOpenChain = Task { @MainActor in
            var restored: [EditorTab] = []
            for url in files {
                let target = Self.mediaRedirectTarget(for: url) ?? url
                guard !tabs.contains(where: { $0.fileURL == target }),
                      !restored.contains(where: { $0.fileURL == target }) else { continue }
                if let tab = await loadDocument(at: target) {
                    restored.append(tab)
                }
            }
            guard !restored.isEmpty else { return }
            // 로드 도중 사용자가 내부 열기로 같은 파일을 먼저 열었을 수 있다(내부 열기는
            // 큐를 안 탄다 — 스펙 §5). append 직전 재필터로 중복 탭 창을 닫는다.
            let fresh = restored.filter { tab in
                !tabs.contains(where: { $0.fileURL == tab.fileURL })
            }
            guard !fresh.isEmpty else { return }
            tabs.append(contentsOf: fresh)
            for tab in fresh { finishOpening(tab) }

            // 방어적 가드 유지(스펙 §2.4) — 체인 밖 경로(사용자 클릭)가 먼저 활성 탭을
            // 만들었으면 덮어쓰지 않는다. 저장 인덱스는 openFiles 기준이므로 URL로 해석
            // (존재 필터·중복 제거로 인덱스가 밀리는 구버전 시프트 수정).
            if Self.shouldRestoreActiveTab(current: activeTabId,
                                           restoredTabIds: Set(fresh.map(\.id))) {
                var activeTab: EditorTab?
                if let index = session.activeFileIndex, index < session.openFiles.count {
                    let savedURL = session.openFiles[index]
                    let target = Self.mediaRedirectTarget(for: savedURL) ?? savedURL
                    activeTab = fresh.first(where: { $0.fileURL == target })
                }
                activeTabId = (activeTab ?? fresh.last)?.id
            }
            saveSession()
        }
    }

    // MARK: - User Data Persistence

    func loadUserData() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
            guard let data = try? Data(contentsOf: dataURL.appendingPathComponent(filename)) else { return nil }
            return try? decoder.decode(type, from: data)
        }

        if let loaded = load(AppSettings.self, from: "settings.json") { settings = loaded }
        if let loaded = load([Vault].self, from: "vaults.json") { vaults = loaded }
        if let loaded = load([URL].self, from: "recents.json") {
            recentFiles = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let loaded = load([VaultTemplate].self, from: "templates.json") { templates = loaded }
        if let loaded = load([RoutingRule].self, from: "rules.json") { routingRules = loaded }
        if let loaded = load([FavoriteItem].self, from: "favorites.json") {
            favorites = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let loaded = load([QuickMoveFolder].self, from: "quickmove-folders.json") {
            quickMoveFolders = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let loaded = load([Draft].self, from: "drafts.json") { drafts = loaded }
    }

    func saveUserData() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        func save<T: Encodable>(_ value: T, to filename: String) {
            if let data = try? encoder.encode(value) {
                try? data.write(to: dataURL.appendingPathComponent(filename))
            }
        }

        save(settings, to: "settings.json")
        save(vaults, to: "vaults.json")
        save(recentFiles, to: "recents.json")
        save(templates, to: "templates.json")
        save(routingRules, to: "rules.json")
        save(favorites, to: "favorites.json")
        save(quickMoveFolders, to: "quickmove-folders.json")
        persistDrafts()
    }

    func persistDrafts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(drafts) {
            try? data.write(to: dataURL.appendingPathComponent("drafts.json"))
        }
    }
}
