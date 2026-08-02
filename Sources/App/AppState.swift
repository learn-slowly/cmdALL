import SwiftUI
import Observation
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
import WebKit
import Quartz

@Observable
final class AppState {
    /// Weak shared reference so the AppDelegate (created independently via
    /// @NSApplicationDelegateAdaptor) can consult app state on quit.
    static weak var shared: AppState?
    static let launchDefaults = AppLaunchDefaults()

    // Tab System
    var tabs: [EditorTab] = []
    var activeTabId: UUID? {
        didSet { activeTabIdChangeCount += 1 }
    }
    /// 테스트 관찰용 — 배치 복원이 활성 탭을 정확히 1회만 지정하는지 검증(스펙 §3-1).
    var activeTabIdChangeCount = 0
    /// 외부 열기(더블클릭·드롭)와 세션 복원을 도착 순으로 직렬 처리하는 체인(스펙 §2.3).
    /// 마지막에 처리된 파일이 활성 탭이 된다. 내부 열기(라이브러리·트리 클릭)는 이 큐를 타지 않는다.
    var externalOpenChain: Task<Void, Never>?
    var documents: [UUID: MarkdownDocument] = [:]
    var originalContents: [UUID: String] = [:]
    /// kordoc 오피스 변환 상태(키 = EditorTab.id). office 탭은 MarkdownDocument가 없다.
    var officeStates: [UUID: OfficeState] = [:]
    /// 검색·옴니서치·RAG 등에서 짝꿍 노트를 줄 번호와 함께 열었다가 media 탭으로
    /// 리다이렉트된 경우, 알림 구독자가 없어 소실되던 줄 정보를 탭별로 담아둔다.
    /// MediaReaderView가 노트 로드 후 소비하고 지운다. 비영속(세션 저장 안 함).
    var pendingMediaScrollLines: [UUID: Int] = [:]
    /// media 탭의 AVPlayer(키 = EditorTab.id). 정지 책임은 뷰가 아니라 AppState가 가진다 —
    /// 창 숨김·탭 전환에서 onDisappear가 신뢰 불가함이 실측됐다(2026-07-03, 오디오 35초+ 잔존).
    /// 시맨틱(사용자 결정, 2026-07-03): 탭 전환 = 재생 유지(백그라운드 청취),
    /// 탭 닫기·메인 창 닫기 = 정지.
    var mediaPlayers: [UUID: AVPlayer] = [:]
    /// 듀얼 페인 칸 미리보기용 미디어 플레이어 키(2026-07-30, 로드맵 §3 후속) — 칸(`BrowsePane`)은
    /// 탭이 아니라 UUID가 없어 `mediaPlayers` 레지스트리를 그대로 못 쓴다. 칸 인덱스(0/1)마다
    /// 고정 키를 하나씩 재사용해 같은 레지스트리·재생/정지 배선(`mediaPlayer(forTab:url:)`)을 그대로 쓴다.
    let panePeekMediaTabIDs: [UUID] = [UUID(), UUID()]

    // View State
    var viewMode: ViewMode = AppState.launchDefaults.viewMode
    var sidebarVisible: Bool = AppState.launchDefaults.sidebarVisible
    var inspectorVisible: Bool = false
    var selectedSidebarTab: SidebarTab = .files

    // 라이브러리 모드 상태
    /// 메인 에디터 영역 모드(reader = 파일 리더, library = 폴더 라이브러리).
    var mainMode: MainMode = .reader
    /// 라이브러리 뷰가 보여줄 폴더. 기본·리셋값은 currentFolder.
    var selectedFolder: URL? = nil {
        didSet {
            restoreLibraryLayoutForSelectedFolder()
            restoreLibrarySortForSelectedFolder()
            // 히스토리 기록 — 전 진입로(드릴인·상위·사이드바 탭·openFolder·즐겨찾기)의
            // 단일 초크포인트. 새 호출부가 push를 빠뜨리는 태스크 경계 결함을 구조로 방지(스펙 §3.2).
            recordNavigationIfNeeded()
            // 폴더 이동 = 선택 해제(Finder 동일, F1b 스펙 §2). 같은 값 재대입은 무시.
            if oldValue != selectedFolder { clearFileSelection() }
        }
    }
    /// 라이브러리 뷰 레이아웃(grid/list). 폴더별 기억 포함.
    var libraryLayout: LibraryLayout = .grid {
        didSet { persistLibraryLayoutForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 libraryLayout didSet이 재저장하지 않도록 막는 플래그.
    var isRestoringLayout = false

    /// 라이브러리·트리 정렬(F3). 폴더별 기억 포함 — 기억 없으면 PARA 기본.
    var librarySort: LibrarySort = .default {
        didSet { persistLibrarySortForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 librarySort didSet이 재저장하지 않도록 막는 플래그.
    var isRestoringSort = false

    // MARK: - 폴더 네비게이션 히스토리 (F3)

    /// 뒤로/앞으로 폴더 히스토리(세션 내 휘발 — SessionState 무변경, 스펙 §3).
    var navHistory = NavigationHistory()
    /// 히스토리 이동·세션 복원·강제 재조준 중 didSet 기록을 막는 플래그(isRestoringLayout 동형).
    var suppressHistoryRecording = false

    // MARK: - 두 폴더 나란히 보기 (듀얼 페인, 로드맵 C/F4)
    /// 두 칸 모드가 켜져 있는가. 꺼져 있으면 지금까지의 한 칸 모드가 완전히 그대로 동작한다(설계 §3.1).
    var dualPaneEnabled: Bool = false
    /// 정확히 2개(왼쪽=0·오른쪽=1). dualPaneEnabled가 꺼져도 마지막 상태를 세션 내에서만 기억한다(디스크 저장 없음, §3.4).
    var panes: [BrowsePane] = []
    /// 사이드바 폴더 클릭·드래그가 향할 칸(0 또는 1) — 마지막으로 포커스를 준 칸(설계 §3.1, 사용자 결정 2).
    var focusedPaneIndex: Int = 0

    /// 두 칸 모드를 켜고 끈다. 켤 때 panes가 비어 있으면(첫 진입) currentFolder로 두 칸을 초기화한다.
    func toggleDualPane() {
        if !dualPaneEnabled, panes.isEmpty, let root = currentFolder {
            panes = [BrowsePane(rootFolder: root), BrowsePane(rootFolder: root)]
            focusedPaneIndex = 0
        } else if dualPaneEnabled {
            // 끌 때 칸 뷰가 사라져도 등록된 미디어 플레이어는 안 멈추면 배경에서 계속 재생된다
            // (§ mediaPlayers 주석과 동일한 사고 — 실측 방지).
            pauseAllPaneMediaPlayers()
        }
        dualPaneEnabled.toggle()
    }

    /// 포커스를 옮긴다(칸을 탭했을 때).
    func focusPane(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        focusedPaneIndex = index
    }

    /// 포커스 있는 칸의 폴더를 바꾼다(사이드바 클릭 라우팅, 설계 §3.1).
    func openFolderInFocusedPane(_ url: URL) {
        guard panes.indices.contains(focusedPaneIndex) else { return }
        panes[focusedPaneIndex].open(folder: url)
    }

    /// 칸 안에서 폴더로 드릴인/이동한다(더블클릭). 그 칸에 포커스도 옮긴다(설계 §3.1).
    func openFolder(inPane index: Int, url: URL) {
        focusPane(index)
        guard panes.indices.contains(index) else { return }
        panes[index].open(folder: url)
    }

    /// 칸 안에서 상위 폴더로 이동한다 — 그 칸의 rootFolder 밑으로는 못 올라간다(라이브러리 §F3 동형 경계).
    func goUpInPane(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        let pane = panes[index]
        guard pane.selectedFolder != pane.rootFolder else { return }
        let parent = pane.selectedFolder.deletingLastPathComponent()
        let parentStd = parent.standardizedFileURL.path
        let rootStd = pane.rootFolder.standardizedFileURL.path
        guard parentStd == rootStd || parentStd.hasPrefix(rootStd + "/") else { return }
        panes[index].open(folder: parent)
    }

    /// 칸 안에서 파일을 읽기 전용으로 열어본다(수정 없음, 설계 §3.2). 그 칸에 포커스도 옮긴다.
    func openPeekFile(_ url: URL, in index: Int) {
        focusPane(index)
        guard panes.indices.contains(index) else { return }
        panes[index].peek(url)
    }

    /// 미리보기를 닫고 목록으로 돌아간다.
    func closePeekFile(in index: Int) {
        guard panes.indices.contains(index) else { return }
        panes[index].clearPeek()
        if panePeekMediaTabIDs.indices.contains(index) {
            mediaPlayers.removeValue(forKey: panePeekMediaTabIDs[index])?.pause()
        }
    }

    /// "큰 화면에서 보기" — 두 칸 모드를 끄고 기존 한 칸 탭 시스템으로 정식으로 연다
    /// (수정·저장·되돌리기 전부 지금과 동일하게 동작, 설계 §3.2).
    func promotePeekFileToTab(_ url: URL) {
        pauseAllPaneMediaPlayers()
        dualPaneEnabled = false
        openDocument(at: url, inNewTab: true)
    }

    /// 사이드바 트리 우클릭 "왼쪽/오른쪽 칸에서 열기" — 두 칸 모드가 꺼져 있으면 이 호출로 자동으로 켠다
    /// (칸이 화면에 있어야 넣을 곳이 생기니까). 폴더면 그 칸이 드릴인한 것처럼 보여주고,
    /// 파일이면 그 칸에서 읽기 전용 미리보기(§3.2)로 연다.
    func openInPane(_ url: URL, isDirectory: Bool, index: Int) {
        if !dualPaneEnabled {
            toggleDualPane()
        }
        if isDirectory {
            openFolder(inPane: index, url: url)
        } else {
            openPeekFile(url, in: index)
        }
    }

    /// 칸이 가리키던 폴더가 rename/trash로 사라졌으면 가장 가까운 존재 조상으로 재조준
    /// (retargetStaleSelectedFolder 동형 패턴, 계획 Task 6). 히스토리 기록 없음.
    func retargetStalePanes() {
        for i in panes.indices {
            let sel = panes[i].selectedFolder
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir), isDir.boolValue { continue }
            var candidate = sel.deletingLastPathComponent()
            while candidate.path != "/" {
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { break }
                candidate = candidate.deletingLastPathComponent()
            }
            panes[i].open(folder: candidate)
        }
    }

    // MARK: - 다중 선택 (F1b)
    /// 라이브러리·트리 공유 선택 집합. URL 키 — FileTreeItem.id는 재빌드마다 새 UUID라 못 쓴다.
    var fileSelection: Set<URL> = []
    /// ⇧범위 선택 앵커(라이브러리 전용).
    var selectionAnchor: URL? = nil
    /// 라이브러리 뷰가 현재 **표시 중인** 항목 순서 — ⌘A·⇧범위의 진실원.
    /// LibraryView.reloadEntries가 갱신. 디스크 재열거 대신 화면에 보이는 목록만 선택하기 위함
    /// (외부에서 추가된, 화면에 없는 파일이 ⌘A로 선택돼 ⌘⌫에 휩쓸리는 것을 방지).
    var libraryOrderedURLs: [URL] = []

    // MARK: - 스페이스바 빠른 보기(스펙 §5)
    /// 빠른 보기로 넘겨볼 파일들(화면 표시 순서).
    var quickLookURLs: [URL] = []
    /// 지금 보고 있는 항목 위치.
    var quickLookIndex: Int = 0
    /// 빠른 보기 오버레이가 떠 있는가.
    var isQuickLookPresented: Bool = false

    // File System
    var vaults: [Vault] = []
    var drafts: [Draft] = []
    var favorites: [FavoriteItem] = []
    var quickMoveFolders: [QuickMoveFolder] = []
    var recentFiles: [URL] = []
    var currentFolder: URL?
    var fileTree: [FileTreeItem] = []
    var expandedFolders: Set<URL> = []

    // Templates & Rules
    var templates: [VaultTemplate] = []
    var routingRules: [RoutingRule] = []

    // Settings
    var settings: AppSettings = AppSettings()

    // Modals & Dialogs
    var showCommandPalette: Bool = false
    var showSendToVault: Bool = false
    var showQuickMove: Bool = false
    var quickMoveTargets: [URL] = []
    var showVaultManager: Bool = false
    var showQuickCapture: Bool = false
    var showOmnisearch: Bool = false
    var showAbout: Bool = false

    // Claude 연동
    var claudePanelVisible: Bool = false
    var claudePanelWidth: CGFloat = 340
    var claudePrompt: String = ""
    var claudeResponse: String?
    var claudeError: String?
    var claudeBusy: Bool = false
    /// 마크다운 에디터의 현재 선택영역 텍스트(없으면 빈 문자열). 질의 컨텍스트 우선순위 1.
    var currentSelectionText: String = ""
    /// PARA 스마트 라우팅 상태.
    var claudeRouteInProgress: Bool = false
    var claudeRouteError: String? = nil
    /// autoRoute 미매칭 → Send 시트가 onAppear에서 자동 제안하도록 켜는 1회성 플래그.
    var autoTriggerClaudeRoute: Bool = false

    // kordoc patch 편집 상태
    var officeEditing: Set<UUID> = []
    var officeEditBuffers: [UUID: String] = [:]
    var officePatchInProgress: Set<UUID> = []
    var officeSaveConfirm: OfficeSaveRequest?
    /// 양식 채우기 시트 구동(키 = 활성 office 탭). nil이면 시트 닫힘.
    var officeFillSession: OfficeFillRequest?
    /// 양식 채우기(dry-run·fill) 진행 중인 탭. 스피너·중복 실행 방지.
    var officeFillInProgress: Set<UUID> = []
    /// "원본 보기" 켜진 탭(격차 5번) — MS 오피스(doc/docx/xls/xlsx)는 macOS 내장 QuickLook,
    /// hwpx는 kordoc render, hwp(구형)는 hwp-convert가 각각 원본 조판을 그린다. hwpml은 아직 없어
    /// 토글 자체가 안 뜬다.
    var officeShowingOriginal: Set<UUID> = []
    /// 오피스 "원본 보기"(kordoc render 또는 hwp-convert) 상태(키 = EditorTab.id). officeShowingOriginal이
    /// 켜져 있고 확장자가 hwpx/hwp일 때만 쓰인다 — MS 오피스(QuickLook)는 이 딕셔너리를 안 씀.
    var officeOriginalRenderStates: [UUID: OfficeOriginalRenderState] = [:]

    // Update checking (GitHub Releases)
    var updateAvailable: Bool = false
    var latestVersion: String?
    var updateURL: URL?
    var isCheckingForUpdate: Bool = false
    /// 앱 내 설치 진행 상태(스펙 §5.5).
    var updateProgress: UpdateProgress = .idle
    /// GitHub 릴리스 태그 원본("v0.9.404"). 자산 URL 조립에 쓴다.
    var latestTag: String?
    /// 종료가 실제로 진행될 때 재실행할 번들. AppDelegate가 읽는다.
    var pendingRelaunchBundleURL: URL?
    /// 진행 중인 설치의 식별자. 완료 후 늦게 도착하는 진행률 보고를 버리는 데 쓴다.
    var installToken: UUID?
    /// Editor/preview width ratio in split view (runtime-only).
    var splitFraction: CGFloat = 0.5
    /// Non-empty while the Send sheet is operating on a batch of files
    /// (e.g. "Send Folder to Vault…") instead of the active document.
    var batchSendURLs: [URL] = []

    // Search
    var folderSearchText: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false
    /// 사이드바 폴더 검색 Task(새 검색 시작 시 이전 것을 취소해 낡은 결과 덮어쓰기 방지).
    var folderSearchTask: Task<Void, Never>?
    /// 파일트리 백그라운드 빌드 Task(연타·연속 호출 시 선행 task 취소).
    var fileTreeTask: Task<Void, Never>?

    // MARK: 자료에 묻기(RAG)
    var showAskCorpus: Bool = false
    var ragQuestion: String = ""
    var ragAnswer: String? = nil
    var ragSources: [RagSource] = []
    var ragBusy: Bool = false
    var ragMessage: String? = nil   // noEvidence·에러 안내

    // 내용 검색(인덱스) 진행 상태 — 검색 화면 자체는 Omnisearch로 통합됐다(§방법2).
    var indexInProgress: Bool = false
    var indexProgress: (done: Int, total: Int)? = nil

    // 폴더 정리(Phase 8) UI 상태
    var showFolderCleanup: Bool = false
    var cleanupMode: CleanupMode?
    var cleanupScheme: CleanupScheme = []
    var cleanupPlan: CleanupPlan?
    var cleanupBusy: Bool = false
    /// 배정 청크 진행 문구("배정 중… (3/10)") — busy 스피너 라벨로 표시. nil이면 기본 문구.
    var cleanupProgress: String? = nil
    var cleanupBatches: [MoveBatch] = []
    var cleanupError: String?

    // MARK: - 위키 인제스트 (LLM-Wiki Ingest)
    var wikiIngestRequest: WikiIngestRequest? = nil
    var wikiBatchRequest: WikiBatchIngestRequest? = nil
    var wikiIngestBusy: Bool = false
    var wikiMergeProposal: WikiMergeProposal? = nil
    var wikiIngestError: String? = nil
    var wikiRulesBusy: Bool = false
    var wikiRulesMessage: String? = nil
    // MARK: - 위키 이력 화면(WikiHistory)
    /// 이력 시트 표시 여부.
    var showWikiHistory: Bool = false
    /// 특정 글만 볼 때의 필터(nil=전체).
    var wikiHistoryPageFilter: URL? = nil
    /// 로드 시 1회 캡처한 이력 행 스냅샷 — 행 클릭으로 재읽기하지 않는다.
    var wikiHistoryRows: [WikiHistoryGrouping.Row] = []
    /// 필터 무관 전체 페이지 목록(글 고르기 Picker용) — 로드 시 1회 캡처.
    var wikiHistoryKnownPages: [URL] = []
    /// 페이지별 마지막 저장 시각 스냅샷("기록 이후 직접 고쳐진 것 같습니다" 힌트용).
    var wikiHistoryPageMTimes: [URL: Date] = [:]
    var wikiHistoryBusy: Bool = false
    var wikiHistoryError: String? = nil
    // MARK: - 위키 관계도 화면(WikiGraph)
    var showWikiGraph: Bool = false
    /// 로드 시 1회 산출한 그래프+레이아웃 스냅샷 — 재계산 없이 뷰가 그대로 그린다.
    var wikiGraphSnapshot: WikiGraphSnapshot? = nil
    var wikiGraphBusy: Bool = false
    var wikiGraphError: String? = nil
    /// nil=전체 보기, 값 있으면 그 노드 중심 1-hop("주변만 보기").
    var wikiGraphFocusedNodeID: String? = nil
    /// 로드 완료 시 1회 결정되는 시작 안내 문구(계획 §관계도 시작 규칙).
    var wikiGraphFocusNotice: String? = nil
    // MARK: - 학습도우미(Study Helper) S1
    var showStudyHelper: Bool = false
    /// 학습 범위(§Q1) — 파일 하나 + 종류.
    var studyScopeFileURL: URL? = nil
    var studyScopeKind: DocumentKind? = nil
    /// 종류(카드/문제)가 바뀌면 선택돼 있던 템플릿이 다른 종류일 수 있어 "기본"으로 되돌린다.
    var studyGenerationKind: StudyItemKind = .card {
        didSet {
            guard oldValue != studyGenerationKind else { return }
            studySelectedTemplateID = nil
        }
    }
    var studyRequestedCount: Int = 5
    /// 선택된 템플릿(레고 2026-08-01 요청 — "정리카드나 연습문제 템플릿을 만들거나 수정").
    /// nil = "기본"(추가 지시 없음, 기존 동작 그대로). `settings.studyTemplates`에서 이 id로 찾는다.
    var studySelectedTemplateID: UUID? = nil
    /// 템플릿 관리 시트 표시 여부.
    var showStudyTemplateManager: Bool = false
    /// 부분 범위 선택(레고 2026-08-01 피드백 — "교재 전체를 한 번에 넣는 건 비현실적") — 기본은
    /// 켜짐(전체 파일, 이전 동작과 호환), 끄면 종류별 범위 UI가 나타난다.
    var studyUseWholeFile: Bool = true
    var studyPDFPageCount: Int = 0
    var studyPageRangeStart: Int = 1
    var studyPageRangeEnd: Int = 1
    /// 마크다운/텍스트 파일의 헤딩 목록(원본 줄 번호 포함) — 시작·끝 헤딩을 고르면 그 사이
    /// 줄 범위로 변환한다.
    var studyHeadingChoices: [StudyHeadingChoice] = []
    var studyLineCount: Int = 0
    var studyHeadingRangeStartIndex: Int = 0
    var studyHeadingRangeEndIndex: Int = 0
    /// 오피스 문서의 구간 목록(kordoc 변환 후 헤딩 경계로 나눈 것) — 변환이 끝나야 채워진다.
    var studySectionChoices: [StudySectionChoice] = []
    var studySectionRangeStart: Int = 1
    var studySectionRangeEnd: Int = 1
    /// 오피스 구간 목록을 kordoc 변환으로 불러오는 동안(화면 "구간 불러오는 중…" 표시용).
    var studyRangeLoading: Bool = false
    /// AC #9 "실행 전 보낼 분량 약 N자 · 조각 C개" — 파일 고를 때 AI 호출 없이 미리 계산.
    var studyPreviewCharCount: Int = 0
    var studyPreviewChunkCount: Int = 0
    var studyBusy: Bool = false
    var studyError: String? = nil
    /// 만드는 중 진행 상황 한 줄("조각 2/5 만드는 중…") — 조각이 2개 이상일 때만 채운다.
    var studyProgress: String? = nil
    /// 진행 막대용 — 지금까지 시작한 조각 수 / 전체 조각 수.
    var studyProgressDone: Int = 0
    var studyProgressTotal: Int = 0
    /// 진행 중인 만들기 태스크 — "취소"가 실제로 중단할 수 있게 핸들을 쥔다(위키 병합 전례).
    var studyGenerateTask: Task<Void, Never>? = nil
    var studyPreviewCards: [StudyCard] = []
    var studyPreviewQuestions: [StudyQuestion] = []
    /// AC #24 "청크 C개 중 k개 성공" + O4 "유효 인용 k/n" 요약 문구.
    var studyOutcomeSummary: String? = nil
    var studySavedNoteURL: URL? = nil
    // MARK: - 학습도우미 대화(S3)
    /// 대화 화면 표시 여부. 학습도우미(S1) 화면에서 범위를 고른 뒤 "대화하며 공부하기"로 연다.
    var showStudyChat: Bool = false
    /// 메모리에만 있는 세션(설계 §4.1) — 크래시 대비 임시 저장(§4.7)은 이번 슬라이스 범위 밖.
    var studyChatSession: StudyChatSession? = nil
    var studyChatText: String = ""
    var studyChatBusy: Bool = false
    var studyChatError: String? = nil
    /// 트리밍이 실제로 발동했을 때만 잠깐 보여주는 안내("이전 대화 일부를 줄여서 보냈어요").
    var studyChatNotice: String? = nil
    var studyChatSavedNoteURL: URL? = nil
    // MARK: - 학습도우미 복습(S2)
    /// 오늘 복습 화면 표시 여부.
    var showStudyReview: Bool = false
    /// 오늘 복습 대기열(§3.9 하루 상한 적용 완료 상태, 기한 오름차순) — 화면은 이 배열만 훑는다.
    var studyReviewQueue: [StudyIndexItem] = []
    var studyReviewIndex: Int = 0
    /// 카드/문제 정답을 보여줄지(문제는 채점 전 정답 숨김, 카드는 항상 펼쳐 보임 — 화면에서 분기).
    var studyReviewRevealAnswer: Bool = false
    var studyReviewBusy: Bool = false
    var studyReviewError: String? = nil
    /// 재빌드 직후 1줄 안내("학습 목록을 다시 훑었습니다: N건(제외 M건)").
    var studyReviewRebuildNotice: String? = nil
    /// 사이드바 리본/메뉴 배지용 — 재빌드·채점 때마다 갱신(§3.9 "신호는 앱 내 배지만").
    var studyDueCount: Int = 0
    /// 방금 채점한 한 건을 되돌리기 위한 스냅숏(직전 1건만, 앱을 닫으면 사라진다).
    var studyReviewUndo: StudyReviewUndo? = nil
    // MARK: - 교재 진도 관리(2026-08-02)
    /// 등록된 교재 + 각각의 진도(진도 노트 파일에서 읽어 계산한 값).
    var studyProgressBooks: [StudyProgressBook] = []
    var studyProgressSelectedID: UUID? = nil
    var studyProgressBusy: Bool = false
    var studyProgressError: String? = nil
    /// 카드·문제를 만든 적 있는데 아직 진도 관리에 등록 안 된 교재(원클릭 등록 후보).
    var studyProgressSuggestions: [URL] = []
    /// 교재 등록 미리보기 — "등록"을 누르기 전까지는 파일이 하나도 생기지 않는다.
    var studyProgressPendingOutline: StudyOutline? = nil
    var studyProgressPendingSource: URL? = nil
    var studyProgressPendingKind: DocumentKind? = nil
    /// 글자 목차 원본(쪽번호 보정을 바꾸면 이걸로 목차를 다시 조립한다).
    var studyProgressPendingTOC: [StudyTOCTextParser.Entry] = []
    var studyProgressPendingOffset: Int = 0
    /// "목차를 어디서 읽었는지" 한 줄 안내.
    var studyProgressPendingSourceLabel: String = ""
    // MARK: - 문서에서 할일 찾기 → Todoist
    var showTaskFinder: Bool = false
    var taskFinderSourceURL: URL? = nil
    var taskFinderCandidates: [TaskCandidate] = []
    /// 기본 선택 원칙: 체크박스 유래는 이미 사용자가 직접 쓴 것이라 기본 ON, AI 유래는
    /// 검토를 유도하려 기본 OFF(§확인 흐름 — "고른 것만 보낸다").
    var taskFinderSelected: Set<UUID> = []
    var taskFinderBusy: Bool = false
    var taskFinderError: String? = nil
    var taskFinderAINotice: String? = nil
    /// 전송 결과 요약("N개 보냈습니다" 등).
    var taskFinderSentSummary: String? = nil
    var todoistProjects: [TodoistProject] = []
    var todoistProjectsLoading: Bool = false
    var todoistProjectsError: String? = nil
    // MARK: - 할일 목록(Todoist 실시간 + 보낸 기록) — 팝업이 아니라 `MainMode.tasks` 화면
    var taskListSelectedTab: TaskListTab = .todoist
    var todoistTasks: [TodoistTask] = []
    var todoistTasksLoading: Bool = false
    var todoistTasksError: String? = nil
    /// 방금 완료 처리한 할일 — "되돌리기"(다듬기 D)로 다시 살릴 수 있게 직전 1건만 기억한다.
    var lastCompletedTodoistTask: TodoistTask? = nil
    var sentTaskRecords: [SentTaskRecord] = []

    // MARK: - 파일 작업(F1a) 상태

    /// 파일작업 세대 토큰 — rename/새폴더/휴지통/되돌리기마다 증가.
    /// LibraryView.folderKey가 결합해 같은 폴더 내 변경도 재열거되게 한다.
    var fileOpsGeneration: Int = 0
    /// 파일 작업 기록 시트.
    var showFileOpsHistory: Bool = false
    /// 이름 변경 시트 요청(.sheet(item:)).
    var renameRequest: RenameRequest? = nil
    /// 사이드바 트리 인라인 이름 변경 대상 — 팝업 시트(renameRequest)와 별개(스펙: 트리는 그 자리 편집).
    var inlineRenameURL: URL? = nil
    /// 정보 보기 시트 요청(.sheet(item:)).
    var fileInfoRequest: FileInfoRequest? = nil
    /// 두 파일 비교 시트 요청(.sheet(item:)) — Docufinder 격차 3번.
    var compareRequest: CompareRequest? = nil
    var compareDiffLines: [LineDiff.Line] = []
    var compareBusy: Bool = false
    var compareError: String? = nil
    /// F2: 진행 중인 내부 드래그의 페이로드(드래그 시작 시 스냅샷) — 드롭 타깃의 hover
    /// 하이라이트 게이팅(DropGuard.dropDecision)이 **내부 세션에서만** 읽는다. 불변식:
    /// 외부(Finder) 세션은 세션 타입으로 판별해 이 스냅샷을 절대 참조하지 않고(stale이어도
    /// 무해 — C1 수정), 내부 세션은 .onDrag가 매번 새로 채운다. 소비 경로(handleFileDrop·창
    /// 레벨·에디터 가드)가 각기 비우므로 잔존값은 사실상 무해(inert).
    var draggingURLs: [URL] = []

    // Claude 인증 상태(설정 화면)
    var claudeAuthStatus: ClaudeAuthStatus?   // nil = CLI 미설치 또는 미확인
    var claudeAuthChecked: Bool = false       // 한 번이라도 status를 조회했는가
    var claudeAuthBusy: Bool = false

    // 챗GPT(codex) 인증 상태(설정 화면) — claudeAuth*와 동일한 3종 세트.
    var codexAuthStatus: CodexAuthStatus?
    var codexAuthChecked: Bool = false
    var codexAuthBusy: Bool = false

    // Status
    var errorMessage: String?
    var toastMessage: String?

    // Editor caret (for the status bar)
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    // Completion index
    var linkableNotes: [VaultNote] = []
    var knownTags: Set<String> = []
    var noteIndexTask: Task<Void, Never>?

    // Services
    let fileService: FileService
    let exportService: ExportService
    let kordocService = KordocService()
    let claudeService = ClaudeService()
    let codexService = CodexService()
    /// 클로드·챗GPT 중 로그인된(설정에 저장된) 쪽으로만 질의를 위임 — cleanupService 등은
    /// 이 라우터 하나만 주입받아 provider 전환 시 재구성 없이 바로 반영된다(init 하단 참고).
    let aiRouter: AIRouterService
    let kordocWriteService = KordocWriteService()
    let kordocFillService = KordocFillService()
    let kordocRenderService = KordocRenderService()
    let hwpConvertRenderService = HwpConvertRenderService()
    let moveLogStore: MoveLogStore
    /// 파일 작업(F1a) 로그 — Task 6·7·8(시트·정보뷰)이 직접 읽으므로 private 아님.
    let fileOpsLogStore: FileOpsLogStore
    /// 테스트가 FakeClaude 주입 CleanupService로 교체할 수 있게 internal var(실사용 재대입 없음).
    var cleanupService: CleanupService
    /// 테스트가 가짜 Claude 주입 WikiIngestService로 교체할 수 있게 internal var(클린업 전례).
    var wikiIngestService: WikiIngestService
    let wikiBackupStore: WikiBackupStore
    let wikiGraphLoader = WikiGraphLoader()
    /// 테스트에서 가짜 Claude 주입 WikiRulesService로 교체할 수 있게 internal var.
    var wikiRulesService: WikiRulesService
    /// StudySourceLoader는 kordocService를 공유(경로+mtime 세션 캐시 재사용).
    let studySourceLoader: StudySourceLoader
    /// 테스트가 가짜 Claude 주입 StudyService로 교체할 수 있게 internal var(클린업 전례).
    var studyService: StudyService
    /// 테스트가 가짜 Claude 주입 StudyChatService로 교체할 수 있게 internal var(위와 동일 전례).
    var studyChatService: StudyChatService
    /// 복습 캐시(§3.8) — init에서 대입(searchIndex와 같은 패턴, appDir 하위 studyindex.sqlite).
    let studyIndex: StudyIndex
    /// 테스트가 가짜 Claude 주입 TaskFinderService로 교체할 수 있게 internal var(클린업 전례).
    var taskFinderService: TaskFinderService
    /// 테스트가 가짜 전송(TodoistTransport) 주입 TodoistService로 교체할 수 있게 internal var.
    var todoistService: TodoistService
    /// "문서에서 할일 찾기 → Todoist" 전송 이력(전례: `MoveLogStore`, init에서 appDir로 대입).
    let sentTaskLogStore: SentTaskLogStore
    let moveExecutor: MoveExecutor
    let dataURL: URL

    // 내용 검색(인덱스) — init에서 대입
    let searchIndex: SearchIndex
    let searchIndexer: SearchIndexer
    let folderWatcher = FolderWatcher()
    let ragService: RagService
    var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]

    // Computed Properties
    var activeTab: EditorTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    var currentDocument: MarkdownDocument? {
        get {
            guard let tab = activeTab else { return nil }
            return documents[tab.documentId]
        }
        set {
            guard let tab = activeTab, let doc = newValue else { return }
            documents[tab.documentId] = doc
        }
    }

    var originalContent: String {
        get {
            guard let tab = activeTab else { return "" }
            return originalContents[tab.documentId] ?? ""
        }
        set {
            guard let tab = activeTab else { return }
            originalContents[tab.documentId] = newValue
        }
    }

    var isDirty: Bool {
        guard let doc = currentDocument else { return false }
        return doc.fullText != originalContent
    }

    var hasAnyDirtyTabs: Bool {
        tabs.contains { isTabDirty($0) }
    }

    func isTabDirty(_ tab: EditorTab) -> Bool {
        guard let doc = documents[tab.documentId],
              let original = originalContents[tab.documentId] else { return false }
        return doc.fullText != original
    }

    var windowTitle: String {
        if let title = currentDocument?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let url = currentTabFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "cmdALL"
    }

    /// 활성 탭의 종류(없으면 마크다운).
    var currentTabKind: DocumentKind {
        activeTab?.kind ?? .markdown
    }

    /// 활성 탭의 파일 URL(이미지 뷰 배선용).
    var currentTabFileURL: URL? {
        activeTab?.fileURL
    }

    var defaultVault: Vault? {
        if let id = settings.defaultVaultId, let vault = vaults.first(where: { $0.id == id }) {
            return vault
        }
        return vaults.first
    }

    /// Resolves the destination folder for a Send. A vault's own Inbox wins when
    /// it is set; otherwise the app-wide `settings.defaultSendFolder` applies,
    /// falling back to "Inbox" so a send always has a valid target.
    func effectiveSendFolder(for vault: Vault) -> String {
        Self.resolveSendFolder(vaultInbox: vault.inboxPath, globalDefault: settings.defaultSendFolder)
    }

    /// Pure resolution rule (extracted so it is unit-testable without a live
    /// AppState): trimmed vault Inbox wins; else the trimmed global default;
    /// else "Inbox".
    static func resolveSendFolder(vaultInbox: String, globalDefault: String) -> String {
        let inbox = vaultInbox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inbox.isEmpty { return inbox }
        let global = globalDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Inbox" : global
    }

    /// The active binding for an action — user override or the default.
    func keyBinding(for shortcut: AppShortcut) -> KeyBinding {
        settings.keyBindings[shortcut.rawValue] ?? shortcut.defaultBinding
    }

    /// 편집 저장의 기본 출력 경로: 원본과 같은 폴더에 "<이름> (편집).<확장자>", 충돌 시 uniquify.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func patchedOutputURL(for original: URL) -> URL {
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        let name = ext.isEmpty ? "\(base) (편집)" : "\(base) (편집).\(ext)"
        return folder.appendingPathComponent(name).uniquified()
    }

    /// fill 출력 기본 경로: 원본과 같은 폴더에 "<이름> (채움).hwpx". fill은 항상 hwpx로 내므로 확장자 강제.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func filledOutputURL(for original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        return folder.appendingPathComponent("\(base) (채움).hwpx").uniquified()
    }

    /// 시트에서 편집한 값(키=FillField.id) 중 "변경됐고 비어있지 않은" 것만 label→value로 모은다.
    /// 빈 문자열은 보내지 않는다(빈 덮어쓰기 방지). 중복 label은 마지막이 우선(kordoc 매칭 한계).
    static func fillValuesToSend(fields: [FillField], edited: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            let v = edited[field.id] ?? field.value
            if v != field.value && !v.isEmpty {
                out[field.label] = v
            }
        }
        return out
    }

    /// - Parameter dataDirectory: 모든 영속(settings.json·session.json·drafts 등)을
    ///   둘 데이터 디렉터리. nil이면 기본 app-support/CmdMD를 쓴다(앱 실행 경로).
    ///   테스트는 빈 임시 디렉터리를 주입해 실제 사용자 설정 오염과 세션 복원
    ///   비결정성을 피한다(빈 디렉터리 → 깨끗한 기본값으로 시작, 세션 복원 없음).
    init(dataDirectory: URL? = nil) {
        // 서브프로세스 stdin write가 broken pipe를 만나도 SIGPIPE로 앱이 죽지 않게 한다.
        signal(SIGPIPE, SIG_IGN)

        let appDir: URL
        if let dataDirectory {
            appDir = dataDirectory
        } else if let override = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"], !override.isEmpty {
            // 데모·스크린샷용 격리 실행 편의 — applicationSupportDirectory는 $HOME 환경변수를
            // 무시하므로(디렉터리 서비스 기반), 실사용 데이터를 건드리지 않는 인스턴스를 띄우려면
            // 이 env로 데이터 디렉터리를 통째로 바꾼다. 일반 실행엔 영향 없음.
            appDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appDir = appSupport.appendingPathComponent("CmdMD")
        }
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir

        moveLogStore = MoveLogStore(directory: appDir)
        fileOpsLogStore = FileOpsLogStore(directory: appDir)
        // provider는 임시로 .claude — 실제 값은 loadUserData() 이후에나 알 수 있어(설정 파일
        // 읽기가 아래에서 늦게 일어남) 로드 후 aiRouter.setProvider로 동기화한다.
        aiRouter = AIRouterService(claude: claudeService, codex: codexService, provider: .claude)
        cleanupService = CleanupService(claude: aiRouter, kordoc: kordocService)
        wikiIngestService = WikiIngestService(claude: aiRouter, kordoc: kordocService)
        wikiBackupStore = WikiBackupStore(directory: appDir)
        wikiRulesService = WikiRulesService(claude: aiRouter)
        studySourceLoader = StudySourceLoader(kordoc: kordocService)
        studyService = StudyService(claude: aiRouter, sourceLoader: studySourceLoader)
        studyChatService = StudyChatService(claude: aiRouter)
        studyIndex = StudyIndex(dbURL: appDir.appendingPathComponent("studyindex.sqlite"))
        taskFinderService = TaskFinderService(claude: aiRouter)
        todoistService = TodoistService()
        sentTaskLogStore = SentTaskLogStore(directory: appDir)
        moveExecutor = MoveExecutor(store: moveLogStore)

        fileService = FileService()
        exportService = ExportService()

        // 인덱스·인덱서 초기화(appDir 재사용, kordocService는 기본값으로 이미 초기화).
        let idx = SearchIndex(dbURL: appDir.appendingPathComponent("searchindex.sqlite"))
        self.searchIndex = idx
        self.searchIndexer = SearchIndexer(index: idx, kordoc: kordocService)
        self.ragService = RagService(index: idx, claude: aiRouter, kordoc: kordocService)

        AppState.shared = self

        loadUserData()
        // 설정에 저장된 provider·모델을 서비스에 동기화 — 위에서 만든 aiRouter/claudeService는
        // 임시(.claude·모델 미지정)였다.
        let savedProvider = settings.aiProvider
        Task { await self.aiRouter.setProvider(savedProvider) }
        let savedClaudeModel = settings.claudeModel
        Task { await self.claudeService.setModel(savedClaudeModel) }
        // 검색 인덱스 스키마가 바뀌어 재구성됐으면 등록 폴더를 자동 재인덱싱(1회).
        Task { @MainActor in await self.reindexAfterSchemaMigration() }
        // 등록 폴더 파일 감시 시작(앱 시작 시 1회).
        Task { @MainActor in self.startFolderWatching() }
        restoreSessionIfNeeded()
        rebuildNoteIndex()
        Task { @MainActor in await self.rebuildStudyIndex() }   // 복습 캐시 앱 시작 1회(§3.7 트리거)
        announceUpdateRestartIfNeeded()   // 업데이트로 재시작했으면 알린다
        checkForUpdates()   // silent, throttled to once per 6h

        NotificationCenter.default.addObserver(
            forName: .showQuickCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showQuickCapture = true
        }

        NotificationCenter.default.addObserver(
            forName: .openInternalLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            self?.openInternalURL(url)
        }
    }

    static let inlineTagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#([a-zA-Z][a-zA-Z0-9_/-]*)"#
    )

    // MARK: - Autosave

    var autosaveWorkItem: DispatchWorkItem?

    // MARK: - Drafts

    var draftPersistWorkItem: DispatchWorkItem?

    /// 진행 중인 병합 생성 태스크 — 시트의 "중단"·닫기가 실제로 취소할 수 있게 핸들을 쥔다.
    var wikiMergeTask: Task<Void, Never>? = nil

    static let wikiTodayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum OfficeState {
    case loading
    case loaded(KordocResult)
    case failed(String)
}

/// 편집 저장 확인 시트를 구동하는 요청. output은 제안 기본 경로이며,
/// 시트의 로컬 상태가 이를 시드로 받아 '위치 변경'을 반영한다.
struct OfficeSaveRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    var output: URL
}

/// 양식 채우기 시트를 구동하는 요청. detection = dry-run 결과, output = 제안 기본 경로(시드).
struct OfficeFillRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    let detection: FillDetection
    var output: URL
}

/// 이름 변경 시트 요청 페이로드.
struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 정보 보기 시트 요청 페이로드.
struct FileInfoRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 두 파일 비교 시트 요청 페이로드(Docufinder 격차 3번 — 문서 버전 비교).
struct CompareRequest: Identifiable {
    let id = UUID()
    let urlA: URL
    let urlB: URL
}

enum SendError: LocalizedError {
    case noDocumentOrVault
    case fileConflict
    case writeError(Error)

    var errorDescription: String? {
        switch self {
        case .noDocumentOrVault:
            return "No document or vault selected"
        case .fileConflict:
            return "File already exists"
        case .writeError(let error):
            return "Write error: \(error.localizedDescription)"
        }
    }
}

// MARK: - URL Uniquifying

extension URL {
    /// Returns self if no file exists at this path, otherwise appends
    /// " (1)", " (2)", … before the extension until the name is free.
    func uniquified() -> URL {
        guard FileManager.default.fileExists(atPath: path) else { return self }
        let baseName = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let parent = deletingLastPathComponent()

        var counter = 1
        var candidate = self
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = parent.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
