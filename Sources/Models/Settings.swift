import Foundation

// MARK: - Preview Settings

struct PreviewSettings: Codable, Equatable {
    var lineHeight: CGFloat = 1.6
    var headingScale: CGFloat = 1.0
    /// Empty (or the legacy "#333333" default) means "use the theme's color".
    var headingColor: String = ""
    var headingMarginTop: CGFloat = 24
    var headingMarginBottom: CGFloat = 16
    var codeBlockTheme: String = "github"
    var customCSS: String = ""
    var maxWidth: CGFloat = 800
    var fontFamily: String = "system-ui"
    var fontSize: CGFloat = 16
    /// 자간 — letter spacing in em.
    var letterSpacing: CGFloat = 0
    /// 단어 간격 — word spacing in em.
    var wordSpacing: CGFloat = 0
    /// 장평 — horizontal glyph scale (1.0 = normal). Applied via scaleX since CSS
    /// has no reflow-safe width property for non-variable fonts.
    var charWidth: CGFloat = 1.0

    /// The heading color to inject, or nil to keep the theme default. "#333333"
    /// was an old default that was never applied; honoring it now would break
    /// dark mode for existing installs, so it is treated as "unset".
    var effectiveHeadingColor: String? {
        let trimmed = headingColor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "#333333" else { return nil }
        return trimmed
    }

    init() {}

    // Resilient decoding: any missing key falls back to its default instead of
    // failing the whole decode (which silently reset every setting whenever a
    // field was added or removed between app versions).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PreviewSettings()
        lineHeight = try c.decodeIfPresent(CGFloat.self, forKey: .lineHeight) ?? d.lineHeight
        headingScale = try c.decodeIfPresent(CGFloat.self, forKey: .headingScale) ?? d.headingScale
        headingColor = try c.decodeIfPresent(String.self, forKey: .headingColor) ?? d.headingColor
        headingMarginTop = try c.decodeIfPresent(CGFloat.self, forKey: .headingMarginTop) ?? d.headingMarginTop
        headingMarginBottom = try c.decodeIfPresent(CGFloat.self, forKey: .headingMarginBottom) ?? d.headingMarginBottom
        codeBlockTheme = try c.decodeIfPresent(String.self, forKey: .codeBlockTheme) ?? d.codeBlockTheme
        customCSS = try c.decodeIfPresent(String.self, forKey: .customCSS) ?? d.customCSS
        maxWidth = try c.decodeIfPresent(CGFloat.self, forKey: .maxWidth) ?? d.maxWidth
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? d.fontSize
        letterSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .letterSpacing) ?? d.letterSpacing
        wordSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .wordSpacing) ?? d.wordSpacing
        charWidth = try c.decodeIfPresent(CGFloat.self, forKey: .charWidth) ?? d.charWidth
    }
}

// MARK: - AI 로그인

/// 폴더 정리·질의·위키 정리에 쓸 AI. 계정이 둘 다 있어도 한 번에 하나만 활성화된다 —
/// 한쪽으로 로그인하면 다른 쪽은 자동 로그아웃된다(AppState.claudeLogin/codexLogin).
enum AIProvider: String, CaseIterable, Codable {
    case claude = "Claude"
    case chatgpt = "ChatGPT"
}

// MARK: - App Settings

struct AppSettings: Codable, Equatable {
    // Appearance
    var theme: AppTheme = .system
    var editorTheme: EditorTheme = .cmds

    // Editor
    var autosaveEnabled: Bool = false
    var autosaveInterval: TimeInterval = 30
    var showLineNumbers: Bool = true
    var softWrap: Bool = true
    var fontSize: CGFloat = 14
    var fontName: String = "SF Mono"
    var tabSize: Int = 4
    var insertSpacesInsteadOfTabs: Bool = true
    var highlightCurrentLine: Bool = true
    var enableAutocompletion: Bool = true

    // Preview
    var previewTheme: String = "CMDS"
    var previewSettings: PreviewSettings = PreviewSettings()
    var enableWikiLinks: Bool = true
    var enableCallouts: Bool = true
    var enableMermaid: Bool = true
    var enableKaTeX: Bool = false
    var enablePreviewCodeHighlight: Bool = true

    // Vault & Sync
    var defaultVaultId: UUID?
    /// App-wide default destination folder for Send. Per-vault Inbox takes
    /// priority when set (see `AppState.effectiveSendFolder(for:)`); this is the
    /// fallback applied when a vault has no Inbox of its own.
    var defaultSendFolder: String = "Inbox"
    var conflictResolution: FileConflictResolution = .rename
    var injectFrontmatterByDefault: Bool = true

    // MARK: AI 로그인
    var aiProvider: AIProvider = .claude   // 폴더 정리·질의·위키 정리에 쓸 활성 AI
    /// 클로드 세션 모델 지정(claude CLI `--model` 별칭·전체이름, 예: "opus"·"sonnet").
    /// 빈 문자열이면 플래그를 넘기지 않고 claude 자체 기본값을 그대로 쓴다(2026-07-31).
    var claudeModel: String = ""

    // MARK: PARA 스마트 라우팅
    var paraVaultId: UUID? = nil           // 지정 PARA 볼트
    var paraFolders: [ParaFolder] = []     // Claude가 고를 후보 목록
    var claudeRoutingEnabled: Bool = false // 자동 라우팅 미매칭 시 Claude 사용(기본 OFF)

    // MARK: 내용 검색
    var indexedFolders: [String] = []      // 내용 검색 인덱스 등록 폴더(절대 경로)
    /// Docufinder 격차 6번 — 스캔 PDF(글자 레이어 없는 이미지 PDF)에서 macOS Vision으로
    /// OCR해 검색 대상에 포함. **기본 OFF** — 사진 한 장 OCR이 일반 글자 추출보다 훨씬
    /// 느려, 이미 대량(16만개+) 폴더를 훑는 중인 사용자의 훑기를 더 늦출 위험이 있다.
    /// 텍스트 레이어가 있는 보통 PDF는 이 설정과 무관하게 항상 그대로 빠르게 색인된다.
    var ocrScannedPDFsEnabled: Bool = false
    /// 사진 속 글자 검색(Docufinder 격차 3번, 이미지 OCR) — png·jpg·jpeg·heic·webp·gif에서
    /// macOS Vision으로 글자를 뽑아 검색 대상에 포함. **기본 OFF**(스캔 PDF OCR과 같은 이유
    /// — 사진 많은 폴더 훑기가 느려질 위험). `ocrScannedPDFsEnabled`와 별개 스위치다.
    var ocrImagesEnabled: Bool = false

    // MARK: 전역 검색 오버레이
    /// ⌘⇧8 — 다른 앱을 보고 있어도 화면 중앙에 검색창을 띄운다(Raycast식). 기본 ON,
    /// 다른 런처 앱과 조합이 겹치면 여기서 끌 수 있다.
    var globalSearchOverlayEnabled: Bool = true

    // MARK: LLM-Wiki 인제스트
    var wikiFolder: String? = nil          // LLM-Wiki 인제스트 대상 폴더(절대 경로)
    var wikiRulesSummary: String? = nil      // 위키 규칙 요약(파악 결과·사용자 편집 가능)
    var wikiRulesCapturedAt: Date? = nil     // 규칙 파악 일시(표시용)
    /// 관계도 화면에서 레고님이 직접 고른 폴더별 색(폴더 경로 → RRGGBB hex). 지정 안 한
    /// 폴더는 이름 기반 자동 색(WikiGraphView.folderColor)을 그대로 쓴다.
    var wikiGraphFolderColors: [String: String] = [:]
    // MARK: 학습도우미 템플릿
    /// 카드·문제 생성 시 기본 지시문에 덧붙일 사용자 템플릿(레고 2026-08-01 요청). 종류(카드/
    /// 문제)별로 여러 개 만들 수 있고, 화면에서 고르지 않으면("기본") 지시문 추가 없이 기존
    /// 동작 그대로다.
    var studyTemplates: [StudyTemplate] = []
    /// 마지막으로 고른 학습 교재 파일(절대경로) — 다음에 학습도우미를 열 때 자동으로
    /// 다시 골라 준다(레고 2026-08-01 요청 "매번 선택하려니 귀찮다"). 파일이 지워지거나
    /// 옮겨졌으면 열 때 실존 확인 후 조용히 무시(에러 없음).
    var lastStudySourcePath: String? = nil
    // MARK: 학습도우미 대화(S3)
    /// 대화 한 턴을 보낼 때 컨텍스트 전체 길이 상한(문자 수, §4.2.2). UI 권장 4,000~40,000,
    /// 0 이하는 저장 거부(설정 화면이 Stepper 범위로 강제). 값을 너무 작게 줄이면 보낼
    /// 자리가 없어 `.noSend`로 안내만 나간다 — 잘린 채 보내는 일은 없다.
    var chatContextCap: Int = 12_000
    /// 오래된 턴을 접을 때 AI로 5줄 요약할지(§4.3). 기본 OFF — 꺼져 있으면 결정적 접기
    /// ("역할: 앞 200자…")만 쓰고 AI 호출이 0회다. 켜도 실패하면 조용히 결정적 접기로 폴백.
    var studyChatAISummary: Bool = false
    // MARK: 학습도우미 복습(S2)
    /// 복습 캐시(§3.7)를 훑을 폴더(절대경로). 비어 있으면 "카드/문제 노트 저장 위치 1곳"이
    /// 기본값(코드에서 계산, `AppState.effectiveStudyFolders()`) — 설정 화면에서 직접 추가한
    /// 폴더가 있으면 그것만 쓴다.
    var studyFolders: [String] = []
    // MARK: 문서에서 할일 찾기 → Todoist 연동
    /// Todoist 개인 API 토큰(Todoist 설정 화면에서 복사). **평문 저장**(다른 설정값과 같은
    /// 파일) — Keychain 연동은 아직 없다. nil/빈 문자열이면 연동 미설정.
    var todoistAPIToken: String? = nil
    /// 기본으로 보낼 프로젝트 id. nil이면 Todoist 기본 받은함(Inbox).
    var todoistDefaultProjectId: String? = nil
    /// 위 id에 대응하는 이름(설정 화면 표시용 — 매번 다시 불러오지 않기 위한 캐시일 뿐,
    /// 실제 전송은 id로만 한다).
    var todoistDefaultProjectName: String? = nil

    // MARK: RAG 설정
    /// 자료에 묻기(RAG) 질의 확장 토글(동의어 recall 보완). 기본 ON.
    var ragExpandQuery: Bool = true

    // MARK: 폴더별 뷰 기억
    /// 키 = 폴더 표준화 경로(`standardizedFileURL.path`), 값 = 기억된 레이아웃.
    var libraryLayouts: [String: LibraryLayout] = [:]

    // MARK: 폴더별 정렬
    /// 키 = 폴더 표준화 경로(`standardizedFileURL.path`), 값 = 기억된 정렬(F3).
    var librarySorts: [String: LibrarySort] = [:]

    // UI
    var showStatusBar: Bool = true
    var showTabBar: Bool = true
    /// 숨김 파일(.으로 시작)을 트리·라이브러리에 표시할지. 보기 전용 — 검색 색인·볼트 작업은 영향 없다.
    var showHiddenFiles: Bool = false
    /// 메뉴바(화면 위쪽) 아이콘 표시 여부. 기본 ON(기존 동작 그대로) — 꺼도 앱 자체는 그대로 실행된다.
    var menuBarIconEnabled: Bool = true
    var sidebarWidth: CGFloat = 250
    var restoreLastSession: Bool = true
    var confirmBeforeClosingDirtyTabs: Bool = true
    var scrollSyncEnabled: Bool = true

    // Onboarding — false until the first-run setup (appearance choice) is done.
    var hasCompletedOnboarding: Bool = false

    // Window — default launch size. Width defaults to fit the Markdown layout
    // (preview max-width + sidebar/ribbon/padding chrome ≈ 800 + 360).
    var defaultWindowWidth: CGFloat = 1160
    var defaultWindowHeight: CGFloat = 820

    // Keyboard — per-action overrides, keyed by AppShortcut.rawValue. Missing
    // entries fall back to AppShortcut.defaultBinding.
    var keyBindings: [String: KeyBinding] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? d.theme
        editorTheme = try c.decodeIfPresent(EditorTheme.self, forKey: .editorTheme) ?? d.editorTheme
        autosaveEnabled = try c.decodeIfPresent(Bool.self, forKey: .autosaveEnabled) ?? d.autosaveEnabled
        autosaveInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .autosaveInterval) ?? d.autosaveInterval
        showLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? d.showLineNumbers
        softWrap = try c.decodeIfPresent(Bool.self, forKey: .softWrap) ?? d.softWrap
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? d.fontSize
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        tabSize = try c.decodeIfPresent(Int.self, forKey: .tabSize) ?? d.tabSize
        insertSpacesInsteadOfTabs = try c.decodeIfPresent(Bool.self, forKey: .insertSpacesInsteadOfTabs) ?? d.insertSpacesInsteadOfTabs
        highlightCurrentLine = try c.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? d.highlightCurrentLine
        enableAutocompletion = try c.decodeIfPresent(Bool.self, forKey: .enableAutocompletion) ?? d.enableAutocompletion
        previewTheme = try c.decodeIfPresent(String.self, forKey: .previewTheme) ?? d.previewTheme
        previewSettings = try c.decodeIfPresent(PreviewSettings.self, forKey: .previewSettings) ?? d.previewSettings
        enableWikiLinks = try c.decodeIfPresent(Bool.self, forKey: .enableWikiLinks) ?? d.enableWikiLinks
        enableCallouts = try c.decodeIfPresent(Bool.self, forKey: .enableCallouts) ?? d.enableCallouts
        enableMermaid = try c.decodeIfPresent(Bool.self, forKey: .enableMermaid) ?? d.enableMermaid
        enableKaTeX = try c.decodeIfPresent(Bool.self, forKey: .enableKaTeX) ?? d.enableKaTeX
        enablePreviewCodeHighlight = try c.decodeIfPresent(Bool.self, forKey: .enablePreviewCodeHighlight) ?? d.enablePreviewCodeHighlight
        defaultVaultId = try c.decodeIfPresent(UUID.self, forKey: .defaultVaultId) ?? d.defaultVaultId
        defaultSendFolder = try c.decodeIfPresent(String.self, forKey: .defaultSendFolder) ?? d.defaultSendFolder
        conflictResolution = try c.decodeIfPresent(FileConflictResolution.self, forKey: .conflictResolution) ?? d.conflictResolution
        injectFrontmatterByDefault = try c.decodeIfPresent(Bool.self, forKey: .injectFrontmatterByDefault) ?? d.injectFrontmatterByDefault
        aiProvider = try c.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? d.aiProvider
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        paraVaultId = try c.decodeIfPresent(UUID.self, forKey: .paraVaultId) ?? d.paraVaultId
        paraFolders = try c.decodeIfPresent([ParaFolder].self, forKey: .paraFolders) ?? d.paraFolders
        claudeRoutingEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeRoutingEnabled) ?? d.claudeRoutingEnabled
        indexedFolders = try c.decodeIfPresent([String].self, forKey: .indexedFolders) ?? d.indexedFolders
        ocrScannedPDFsEnabled = try c.decodeIfPresent(Bool.self, forKey: .ocrScannedPDFsEnabled) ?? d.ocrScannedPDFsEnabled
        ocrImagesEnabled = try c.decodeIfPresent(Bool.self, forKey: .ocrImagesEnabled) ?? d.ocrImagesEnabled
        globalSearchOverlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalSearchOverlayEnabled) ?? d.globalSearchOverlayEnabled
        wikiFolder = try c.decodeIfPresent(String.self, forKey: .wikiFolder) ?? d.wikiFolder
        wikiRulesSummary = try c.decodeIfPresent(String.self, forKey: .wikiRulesSummary) ?? d.wikiRulesSummary
        wikiRulesCapturedAt = try c.decodeIfPresent(Date.self, forKey: .wikiRulesCapturedAt) ?? d.wikiRulesCapturedAt
        wikiGraphFolderColors = try c.decodeIfPresent([String: String].self, forKey: .wikiGraphFolderColors) ?? d.wikiGraphFolderColors
        studyTemplates = try c.decodeIfPresent([StudyTemplate].self, forKey: .studyTemplates) ?? d.studyTemplates
        lastStudySourcePath = try c.decodeIfPresent(String.self, forKey: .lastStudySourcePath) ?? d.lastStudySourcePath
        chatContextCap = try c.decodeIfPresent(Int.self, forKey: .chatContextCap) ?? d.chatContextCap
        studyChatAISummary = try c.decodeIfPresent(Bool.self, forKey: .studyChatAISummary) ?? d.studyChatAISummary
        studyFolders = try c.decodeIfPresent([String].self, forKey: .studyFolders) ?? d.studyFolders
        todoistAPIToken = try c.decodeIfPresent(String.self, forKey: .todoistAPIToken) ?? d.todoistAPIToken
        todoistDefaultProjectId = try c.decodeIfPresent(String.self, forKey: .todoistDefaultProjectId) ?? d.todoistDefaultProjectId
        todoistDefaultProjectName = try c.decodeIfPresent(String.self, forKey: .todoistDefaultProjectName) ?? d.todoistDefaultProjectName
        ragExpandQuery = try c.decodeIfPresent(Bool.self, forKey: .ragExpandQuery) ?? d.ragExpandQuery
        libraryLayouts = try c.decodeIfPresent([String: LibraryLayout].self, forKey: .libraryLayouts) ?? d.libraryLayouts
        librarySorts = try c.decodeIfPresent([String: LibrarySort].self, forKey: .librarySorts) ?? d.librarySorts
        showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? d.showStatusBar
        showTabBar = try c.decodeIfPresent(Bool.self, forKey: .showTabBar) ?? d.showTabBar
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? d.showHiddenFiles
        menuBarIconEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarIconEnabled) ?? d.menuBarIconEnabled
        sidebarWidth = try c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        restoreLastSession = try c.decodeIfPresent(Bool.self, forKey: .restoreLastSession) ?? d.restoreLastSession
        confirmBeforeClosingDirtyTabs = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeClosingDirtyTabs) ?? d.confirmBeforeClosingDirtyTabs
        scrollSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .scrollSyncEnabled) ?? d.scrollSyncEnabled
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        defaultWindowWidth = try c.decodeIfPresent(CGFloat.self, forKey: .defaultWindowWidth) ?? d.defaultWindowWidth
        defaultWindowHeight = try c.decodeIfPresent(CGFloat.self, forKey: .defaultWindowHeight) ?? d.defaultWindowHeight
        keyBindings = try c.decodeIfPresent([String: KeyBinding].self, forKey: .keyBindings) ?? d.keyBindings
    }
}
