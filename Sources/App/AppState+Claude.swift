import Foundation

extension AppState {

    // MARK: - Claude 연동

    /// 선택영역은 마크다운 탭에서만 컨텍스트로 쓴다. 다른 종류 탭에선 이전 마크다운
    /// 선택이 새지 않도록 빈 문자열로 친다.
    static func claudeSelection(forKind kind: DocumentKind, selection: String) -> String {
        kind == .markdown ? selection : ""
    }

    /// 질의 컨텍스트를 고른다(순수 함수). 선택영역 > 마크다운 본문 > 오피스 변환 마크다운 > 빈 문자열.
    static func claudeContext(selection: String, markdown: String?, officeMarkdown: String?, mediaNote: String? = nil) -> String {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty { return sel }
        if let md = markdown, !md.isEmpty { return md }
        if let om = officeMarkdown, !om.isEmpty { return om }
        if let mn = mediaNote, !mn.isEmpty { return mn }
        return ""
    }

    /// 파일 우클릭 "Claude로 요약"에 노출할지(순수 함수) — 글자로 뽑아낼 수 있는 종류만.
    /// office(kordoc)·pdf·일반 텍스트·이메일(.eml)은 되고, 이미지·미디어·모르는 형식
    /// (QuickLook 폴백)은 제외.
    static func isSummarizable(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "eml" { return true }
        if DocumentKind.officeExtensions.contains(ext) { return true }
        if DocumentKind.pdfExtensions.contains(ext) { return true }
        return QuickLookRouting.opensAsText(extension: ext)
    }

    /// 우클릭 다중 선택 메뉴에서 "두 파일 비교…"를 보여줄지 판정. 정확히 2개 + 둘 다
    /// 폴더가 아니고 글자로 뽑을 수 있는 종류(office/pdf/텍스트)일 때만 순서대로 반환.
    static func comparablePair(_ targets: [URL]) -> (URL, URL)? {
        guard targets.count == 2 else { return nil }
        let files = targets.filter { url in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && !isDir.boolValue && isSummarizable(url: url)
        }
        guard files.count == 2 else { return nil }
        return (files[0], files[1])
    }

    /// ClaudeError를 사용자용 한국어 안내로 변환한다(순수 함수).
    static func claudeErrorMessage(_ error: Error) -> String {
        switch error {
        case ClaudeError.toolNotFound:
            return "claude CLI를 찾을 수 없습니다. 설치 후 터미널에서 `claude`로 로그인하고 다시 시도하세요."
        case ClaudeError.notLoggedIn:
            return "Claude Code 로그인이 필요합니다. 터미널에서 `claude`를 실행해 로그인한 뒤 다시 시도하세요."
        case ClaudeError.creditExhausted:
            return "Claude 사용량(크레딧)이 소진되었습니다. 잠시 후 다시 시도하세요."
        case ClaudeError.timeout:
            return "응답이 너무 오래 걸려 중단했습니다."
        case ClaudeError.failed(let m):
            return "Claude 호출에 실패했습니다: \(m)"
        default:
            return "Claude 호출에 실패했습니다: \(error.localizedDescription)"
        }
    }

    /// ClaudeError를 챗GPT(codex) 맥락의 한국어 안내로 변환한다(순수 함수). 에러 타입은
    /// 공용 ClaudeError를 재사용하지만(CodexService 참고) 사용자에게 보여줄 이름은 다르게 한다.
    static func codexErrorMessage(_ error: Error) -> String {
        switch error {
        case ClaudeError.toolNotFound:
            return "codex CLI를 찾을 수 없습니다. 설치 후 설정에서 ‘브라우저로 로그인’을 눌러 로그인하고 다시 시도하세요."
        case ClaudeError.notLoggedIn:
            return "ChatGPT 로그인이 필요합니다. 설정에서 ‘브라우저로 로그인’을 눌러 로그인한 뒤 다시 시도하세요."
        case ClaudeError.creditExhausted:
            return "ChatGPT 사용량이 소진되었습니다. 잠시 후 다시 시도하세요."
        case ClaudeError.timeout:
            return "응답이 너무 오래 걸려 중단했습니다."
        case ClaudeError.failed(let m):
            return "ChatGPT 호출에 실패했습니다: \(m)"
        default:
            return "ChatGPT 호출에 실패했습니다: \(error.localizedDescription)"
        }
    }

    /// 현재 활성 AI(설정의 aiProvider)에 맞는 에러 안내를 고른다 — 폴더 정리·질의·위키
    /// 기능처럼 provider 무관 공용 코드에서 쓴다.
    static func aiErrorMessage(_ error: Error, provider: AIProvider) -> String {
        provider == .claude ? claudeErrorMessage(error) : codexErrorMessage(error)
    }

    // MARK: - PARA 스마트 라우팅

    /// PARA 볼트와 폴더가 모두 설정됐고 그 볼트가 실제 등록돼 있는가(버튼 활성/가드용).
    func isParaRoutingConfigured() -> Bool {
        guard let id = settings.paraVaultId, !settings.paraFolders.isEmpty else { return false }
        return vaults.contains { $0.id == id }
    }

    /// 설정된 PARA 볼트 객체(없으면 nil).
    var paraVault: Vault? {
        guard let id = settings.paraVaultId else { return nil }
        return vaults.first { $0.id == id }
    }

    /// 본문을 Claude에 보내 PARA 폴더 제안을 받는다. 실패 시 claudeRouteError 세팅 후 nil.
    @MainActor
    func requestClaudeRoute(noteBody: String) async -> RouteSuggestion? {
        guard isParaRoutingConfigured() else {
            claudeRouteError = "설정에서 PARA 볼트와 폴더를 먼저 추가하세요."
            return nil
        }
        claudeRouteError = nil
        claudeRouteInProgress = true
        defer { claudeRouteInProgress = false }
        let dests = settings.paraFolders
        let prompt = RouteHelper.buildRoutePrompt(destinations: dests)
        let context = RouteHelper.buildRouteContext(noteBody: noteBody)
        do {
            let out = try await aiRouter.ask(prompt: prompt, context: context)
            if let suggestion = RouteHelper.parseRouteSuggestion(out, destinations: dests) {
                return suggestion
            }
            claudeRouteError = "AI 제안을 해석하지 못했습니다. 직접 골라 주세요."
            return nil
        } catch {
            claudeRouteError = Self.aiErrorMessage(error, provider: settings.aiProvider)
            return nil
        }
    }

    /// 현재 문서(또는 선택영역)를 프롬프트와 함께 claude에 보내고 응답을 패널에 표시한다.
    func askClaude() {
        let prompt = claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !claudeBusy else { return }

        let officeMarkdown: String? = {
            guard let tab = activeTab, case .loaded(let result)? = officeStates[tab.id] else { return nil }
            return result.markdown
        }()
        let selection = Self.claudeSelection(forKind: currentTabKind, selection: currentSelectionText)
        // media 탭이면 짝꿍 노트 전문을 컨텍스트로(frontmatter 포함 — duration·summary 메타가 질문에 유용).
        // 한계: 편집 중 미저장 버퍼는 뷰 로컬 @State라 디스크 기준(탭 전환 시 자동저장돼 실사용 영향 작음).
        let mediaNote: String? = {
            guard currentTabKind == .media, let url = currentTabFileURL else { return nil }
            return try? String(contentsOf: CompanionNote.noteURL(for: url), encoding: .utf8)
        }()
        let context = Self.claudeContext(selection: selection,
                                         markdown: currentDocument?.content,
                                         officeMarkdown: officeMarkdown,
                                         mediaNote: mediaNote)

        claudeBusy = true
        claudeError = nil
        claudeResponse = nil

        Task { @MainActor in
            do {
                var acc = ""
                let stream = await aiRouter.askStream(prompt: prompt, context: context)
                for try await chunk in stream {
                    acc += chunk
                    claudeResponse = acc          // @Observable — 패널이 실시간 갱신
                }
                if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    claudeResponse = nil
                    claudeError = "AI가 빈 응답을 반환했습니다. 다시 시도해 주세요."
                }
            } catch {
                claudeResponse = nil
                claudeError = Self.aiErrorMessage(error, provider: settings.aiProvider)
            }
            claudeBusy = false
        }
    }
    /// 파일 우클릭 "Claude로 요약" — 파일을 탭으로 열지 않고도 내용을 뽑아 요약을 요청한다.
    /// askClaude()와 같은 패널(claudeResponse 등)을 그대로 재사용 — 새 UI 없음. 컨텍스트는
    /// 열린 문서가 아니라 `ContentExtractor`로 그 자리에서 새로 뽑는다(office는 kordoc 경유).
    func summarizeFile(at url: URL) {
        guard !claudeBusy else { return }
        claudePrompt = "이 문서를 한국어로 짧게 요약해줘. 핵심 내용과 중요한 숫자·날짜가 있으면 놓치지 말고 짚어줘."
        claudeBusy = true
        claudeError = nil
        claudeResponse = nil
        claudePanelVisible = true

        Task { @MainActor in
            guard let body = await ContentExtractor.body(for: url, kordoc: kordocService),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                claudeBusy = false
                claudeError = "이 파일에서 읽을 수 있는 글자를 찾지 못했습니다(빈 문서이거나 지원하지 않는 형식)."
                return
            }
            do {
                var acc = ""
                let stream = await aiRouter.askStream(prompt: claudePrompt, context: body)
                for try await chunk in stream {
                    acc += chunk
                    claudeResponse = acc
                }
                if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    claudeResponse = nil
                    claudeError = "AI가 빈 응답을 반환했습니다. 다시 시도해 주세요."
                }
            } catch {
                claudeResponse = nil
                claudeError = Self.aiErrorMessage(error, provider: settings.aiProvider)
            }
            claudeBusy = false
        }

    }

    /// 파일 우클릭(2개 선택) → "두 파일 비교…" — Docufinder 격차 3번. 나란히(2단) 대신
    /// 기존 위키 인제스트가 쓰는 통합(unified) diff 컴포넌트(`LineDiff`·`WikiDiffListView`)를
    /// 재사용한다(2026-07-27 결정 — 새 레이아웃 없이 기존 것으로 "달라진 부분 표시"를 충족).
    func requestCompare(urlA: URL, urlB: URL) {
        guard !compareBusy else { return }
        compareRequest = CompareRequest(urlA: urlA, urlB: urlB)
        compareDiffLines = []
        compareError = nil
        compareBusy = true

        Task { @MainActor in
            async let bodyA = ContentExtractor.body(for: urlA, kordoc: kordocService)
            async let bodyB = ContentExtractor.body(for: urlB, kordoc: kordocService)
            let (a, b) = await (bodyA, bodyB)
            guard let a, let b else {
                compareBusy = false
                compareError = "두 파일 중 하나 이상에서 읽을 수 있는 글자를 찾지 못했습니다(빈 문서이거나 지원하지 않는 형식)."
                return
            }
            compareDiffLines = LineDiff.diff(old: a, new: b)
            compareBusy = false
        }
    }

    // MARK: - Claude 응답 저장(본문 삽입·노트로 저장)

    /// 프롬프트를 새 노트 제목으로 다듬는다(순수 함수). 트림 후 개행은 공백으로 바꾸고
    /// 파일명이 과도하게 길어지지 않도록 40자에서 자른다. 빈 프롬프트는 기본 제목으로.
    static func noteTitle(fromPrompt prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return "Claude 응답" }
        return String(trimmed.prefix(40))
    }

    /// Claude 응답을 현재 노트 본문에 반영한다. 마크다운 탭에서만 동작(다른 종류는 무시).
    /// 에디터가 붙어 있는 reader 모드의 source/split에선 커서 위치 삽입을 알림으로 위임하고,
    /// 그 외엔 본문 끝에 덧붙인다(insertImageMarkdown과 같은 패턴) — 라이브러리 모드는
    /// MarkdownTextEditor가 비마운트라 구독자가 없고, reader의 preview는 에디터가 오프스크린
    /// 마운트 상태지만 커서/포커스가 없어 커서 삽입이 무의미하다.
    func insertClaudeResponseIntoCurrentNote() {
        guard currentTabKind == .markdown, let doc = currentDocument,
              let resp = claudeResponse, !resp.isEmpty else { return }
        let block = "\n\n" + resp + "\n"
        if mainMode == .reader && viewMode != .preview {
            NotificationCenter.default.post(name: .insertClaudeResponse, object: block)
        } else {
            updateContent(doc.content + block)
        }
    }

    /// Claude 응답을 기본 볼트에 새 노트로 저장한다. 원본 문서는 손대지 않는다
    /// (QuickCaptureView.sendToVault와 같은 패턴 — 이쪽은 활성 탭 없이도 동작).
    /// 성공 시 true, 실패(응답 없음·볼트 미설정·sendToVault 오류)면 false를 반환한다 —
    /// 호출부가 이 반환값으로 성공 피드백 표시 여부를 게이트해야 한다(post-hoc claudeError
    /// 검사보다 견고: claudeError는 이전 호출의 stale 값이 남아있을 수 있음).
    @MainActor
    @discardableResult
    func saveClaudeResponseAsNote() async -> Bool {
        guard let resp = claudeResponse, !resp.isEmpty else { return false }
        guard let vault = defaultVault else {
            claudeError = "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요."
            return false
        }
        let doc = MarkdownDocument(title: Self.noteTitle(fromPrompt: claudePrompt), content: resp, isDraft: true)
        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = effectiveSendFolder(for: vault)
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = settings.injectFrontmatterByDefault
        do {
            try await sendToVault(document: doc, options: options, quiet: true)
            return true
        } catch {
            claudeError = "노트 저장 실패: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - AI 로그인 (설정 화면) — 클로드 · 챗GPT 중 한 번에 하나만 활성화

    /// `claude auth status`를 조회해 화면 상태를 갱신한다.
    @MainActor
    func refreshClaudeAuth() async {
        claudeAuthBusy = true
        defer { claudeAuthBusy = false }
        claudeAuthStatus = await claudeService.authStatus()
        claudeAuthChecked = true
    }

    /// `codex login status`를 조회해 화면 상태를 갱신한다.
    @MainActor
    func refreshCodexAuth() async {
        codexAuthBusy = true
        defer { codexAuthBusy = false }
        codexAuthStatus = await codexService.authStatus()
        codexAuthChecked = true
    }

    /// `claude auth login`(브라우저 로그인) 실행. 성공하면 챗GPT는 자동 로그아웃하고 활성
    /// AI를 클로드로 전환한다 — 계정이 둘 다 있어도 한 번에 하나만 쓴다는 요구사항(설정 화면
    /// 경고 문구와 짝) 때문. 로그인 자체가 실패하면 provider는 그대로 둔다.
    @MainActor
    func claudeLogin() async {
        claudeAuthBusy = true
        do {
            try await claudeService.login()
            try? await codexService.logout()   // best-effort — 실패해도 클로드 전환은 진행
            settings.aiProvider = .claude
            await aiRouter.setProvider(.claude)
            saveUserData()
        } catch let error as ClaudeError {
            errorMessage = Self.claudeErrorMessage(error)
        } catch {
            errorMessage = "Claude 로그인에 실패했습니다."
        }
        claudeAuthBusy = false
        await refreshClaudeAuth()
        await refreshCodexAuth()   // 로그인 성공 시 챗GPT가 로그아웃됐으므로 화면도 갱신
    }

    /// `codex login`(브라우저 로그인) 실행. 성공하면 클로드는 자동 로그아웃하고 활성 AI를
    /// 챗GPT로 전환한다(claudeLogin과 대칭 — 위 주석 참고).
    @MainActor
    func codexLogin() async {
        codexAuthBusy = true
        do {
            try await codexService.login()
            try? await claudeService.logout()   // best-effort
            settings.aiProvider = .chatgpt
            await aiRouter.setProvider(.chatgpt)
            saveUserData()
        } catch let error as ClaudeError {
            errorMessage = Self.codexErrorMessage(error)
        } catch {
            errorMessage = "ChatGPT 로그인에 실패했습니다."
        }
        codexAuthBusy = false
        await refreshCodexAuth()
        await refreshClaudeAuth()
    }

    /// 로그아웃 후 상태를 새로고침한다. (다른 provider·활성 AI 선택은 건드리지 않는다 —
    /// 로그인 전환과 달리 로그아웃은 그 서비스 하나에 한정된 명시적 동작.)
    @MainActor
    func claudeLogout() async {
        claudeAuthBusy = true
        try? await claudeService.logout()
        claudeAuthBusy = false
        await refreshClaudeAuth()
    }

    /// 로그아웃 후 상태를 새로고침한다.
    @MainActor
    func codexLogout() async {
        codexAuthBusy = true
        try? await codexService.logout()
        codexAuthBusy = false
        await refreshCodexAuth()
    }

    func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }
}
