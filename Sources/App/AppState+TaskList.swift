import Foundation

/// "할일 목록 보기" 화면 — `TaskListView` 배선. 두 탭(Todoist 실시간·이 앱이 보낸 기록)을
/// 채운다. 실제 API 호출은 `TodoistService`, 이력 저장은 `SentTaskLogStore`에 있다.
extension AppState {

    /// 할일 화면으로 전환한다 — 팝업이 아니라 파일 화면(리더·라이브러리)과 같은 메인 모드
    /// 전환이다(레고 2026-08-01 "이걸 파일 화면 보듯이 해줘"). 데이터 로드는 화면이 뜨면서
    /// `TaskListView.task`가 `loadTaskListData()`로 부른다.
    func openTaskListView() {
        mainMode = .tasks
    }

    /// 두 탭에 필요한 데이터를 한 번에 채운다(진입·재진입 공용).
    @MainActor
    func loadTaskListData() async {
        await refreshTodoistTasks()
        await loadSentTaskRecords()
    }

    /// 등록한 프로젝트 구분 없이 통틀어 가져온다(레고 결정 — "모든 프로젝트 통틀어 다 보기").
    @MainActor
    func refreshTodoistTasks() async {
        guard let token = settings.todoistAPIToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            todoistTasksError = TodoistService.errorMessage(TodoistError.noToken)
            return
        }
        todoistTasksLoading = true
        todoistTasksError = nil
        defer { todoistTasksLoading = false }
        do {
            todoistTasks = try await todoistService.fetchTasks(token: token)
        } catch {
            todoistTasks = []
            todoistTasksError = TodoistService.errorMessage(error)
        }
    }

    @MainActor
    func loadSentTaskRecords() async {
        sentTaskRecords = await sentTaskLogStore.loadNewestFirst()
    }

    /// 체크하면 Todoist에서도 실제로 완료 처리된다(레고 결정 — "양방향"). 실패하면 목록에
    /// 그대로 남아 있어(낙관적 갱신 없음) 사용자가 다시 시도할 수 있다.
    @MainActor
    func completeTodoistTask(_ task: TodoistTask) async {
        guard let token = settings.todoistAPIToken, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            todoistTasksError = TodoistService.errorMessage(TodoistError.noToken)
            return
        }
        do {
            try await todoistService.closeTask(taskId: task.id, token: token)
            todoistTasks.removeAll { $0.id == task.id }
        } catch {
            todoistTasksError = TodoistService.errorMessage(error)
        }
    }
}
