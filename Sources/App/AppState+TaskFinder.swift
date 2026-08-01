import Foundation

/// "문서에서 할일 찾아서 등록" — `TaskFinderView` 배선. 실제 탐지 로직은
/// `TaskFinderService`/`TaskExtractor`/`TaskOutputParser`, 전송은 `TodoistService`에 있고,
/// 이 파일은 화면 진입점 + 상태만 잇는다.
extension AppState {

    /// 지금 열어본 문서(활성 탭)를 대상으로 시트를 열고 곧바로 탐지를 시작한다.
    /// 요약 가능한 종류(office/pdf/텍스트/이메일)가 아니면 안내만 하고 시트를 안 연다.
    func openTaskFinder() {
        guard let url = currentTabFileURL, Self.isSummarizable(url: url) else {
            taskFinderError = "이 문서에서는 할일을 찾을 수 없습니다(읽을 수 있는 글자가 있는 문서에서만 됩니다)."
            showTaskFinder = true
            return
        }
        taskFinderSourceURL = url
        taskFinderCandidates = []
        taskFinderSelected = []
        taskFinderError = nil
        taskFinderAINotice = nil
        taskFinderSentSummary = nil
        showTaskFinder = true
        Task { @MainActor in await runTaskFinder(at: url) }
    }

    @MainActor
    func runTaskFinder(at url: URL) async {
        taskFinderBusy = true
        defer { taskFinderBusy = false }
        guard let body = await ContentExtractor.body(for: url, kordoc: kordocService,
                                                       ocrScannedPDFs: settings.ocrScannedPDFsEnabled),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            taskFinderError = "이 문서에서 읽을 수 있는 글자를 찾지 못했습니다."
            return
        }
        let isMarkdown = DocumentKind.markdownExtensions.contains(url.pathExtension.lowercased())
        let result = await taskFinderService.findTasks(body: body, isMarkdown: isMarkdown)
        taskFinderCandidates = result.candidates
        taskFinderAINotice = result.aiError
        // 기본 선택: 체크박스 유래만 켜둔다(§확인 흐름 — AI 유래는 검토 후 사용자가 직접 고른다).
        taskFinderSelected = Set(result.candidates.filter { $0.source == .checkbox }.map(\.id))
        if result.candidates.isEmpty && result.aiError == nil {
            taskFinderError = "이 문서에서 할일로 볼 만한 내용을 찾지 못했습니다."
        }
    }

    @MainActor
    func toggleTaskFinderSelection(_ id: UUID) {
        if taskFinderSelected.contains(id) {
            taskFinderSelected.remove(id)
        } else {
            taskFinderSelected.insert(id)
        }
    }

    @MainActor
    func closeTaskFinder() {
        showTaskFinder = false
        taskFinderSourceURL = nil
        taskFinderCandidates = []
        taskFinderSelected = []
        taskFinderError = nil
        taskFinderAINotice = nil
        taskFinderSentSummary = nil
    }

    /// 고른 후보만 순서대로 Todoist에 생성한다. 하나 실패해도 나머지는 계속 시도하고
    /// 마지막에 "N개 중 k개 보냈습니다"로 집계(전례: 카드/문제 청크 부분 성공 표시).
    @MainActor
    func sendSelectedTasksToTodoist() async {
        guard let token = settings.todoistAPIToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            taskFinderError = TodoistService.errorMessage(TodoistError.noToken)
            return
        }
        let selected = taskFinderCandidates.filter { taskFinderSelected.contains($0.id) }
        guard !selected.isEmpty else { return }

        taskFinderBusy = true
        taskFinderError = nil
        defer { taskFinderBusy = false }

        var sentIDs: Set<UUID> = []
        var lastError: Error?
        for candidate in selected {
            do {
                let created = try await todoistService.createTask(
                    content: candidate.text, projectId: settings.todoistDefaultProjectId, token: token)
                sentIDs.insert(candidate.id)
                let record = SentTaskRecord(
                    id: UUID(), text: candidate.text,
                    sourceFileName: taskFinderSourceURL?.lastPathComponent,
                    sourcePath: taskFinderSourceURL?.path,
                    sentAt: Date(), todoistTaskId: created?.id)
                await sentTaskLogStore.append(record)
            } catch {
                lastError = error
            }
        }

        if !sentIDs.isEmpty {
            // 보낸 것만 후보·선택 목록에서 뺀다 — 실패분은 남겨 재시도할 수 있게 한다.
            taskFinderCandidates.removeAll { sentIDs.contains($0.id) }
            taskFinderSelected.subtract(sentIDs)
        }
        if sentIDs.count == selected.count {
            taskFinderSentSummary = "\(sentIDs.count)개 보냈습니다."
        } else {
            taskFinderSentSummary = "\(selected.count)개 중 \(sentIDs.count)개 보냈습니다."
            if let lastError { taskFinderError = TodoistService.errorMessage(lastError) }
        }
    }

    // MARK: - 설정 화면: Todoist 연동

    /// "연결 확인" — 토큰으로 프로젝트 목록을 가져온다. 성공하면 그 자체가 토큰 검증이다.
    @MainActor
    func loadTodoistProjects() async {
        guard let token = settings.todoistAPIToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            todoistProjectsError = TodoistService.errorMessage(TodoistError.noToken)
            return
        }
        todoistProjectsLoading = true
        todoistProjectsError = nil
        defer { todoistProjectsLoading = false }
        do {
            todoistProjects = try await todoistService.fetchProjects(token: token)
        } catch {
            todoistProjects = []
            todoistProjectsError = TodoistService.errorMessage(error)
        }
    }

    @MainActor
    func selectTodoistDefaultProject(_ project: TodoistProject?) {
        settings.todoistDefaultProjectId = project?.id
        settings.todoistDefaultProjectName = project?.name
        saveUserData()
    }
}
