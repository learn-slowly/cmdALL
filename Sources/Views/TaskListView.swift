import SwiftUI

/// "할일 목록 보기" — Todoist 실시간 할일(모든 프로젝트 통틀어) + 이 앱이 문서에서 찾아
/// Todoist로 보낸 기록, 두 탭. 실제 로직은 `AppState+TaskList.swift`/`TodoistService`/
/// `SentTaskLogStore`에 있고, 이 화면은 배선만 부른다.
struct TaskListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $state.taskListSelectedTab) {
                Text("Todoist 할일").tag(TaskListTab.todoist)
                Text("보낸 기록").tag(TaskListTab.sentHistory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if appState.taskListSelectedTab == .todoist {
                todoistTab
            } else {
                historyTab
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
    }

    private var header: some View {
        HStack {
            Text("할일 목록").font(.headline)
            Spacer()
            Button("닫기") { appState.closeTaskListView() }
        }
    }

    // MARK: - Todoist 실시간 탭

    @ViewBuilder
    private var todoistTab: some View {
        HStack {
            Spacer()
            Button("새로고침") { Task { await appState.refreshTodoistTasks() } }
                .disabled(appState.todoistTasksLoading)
        }
        if let error = appState.todoistTasksError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if appState.todoistTasksLoading && appState.todoistTasks.isEmpty {
            Spacer()
            ProgressView("불러오는 중…")
            Spacer()
        } else if appState.todoistTasks.isEmpty {
            Spacer()
            Text("할일이 없습니다.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.todoistTasks) { task in
                        todoistTaskRow(task)
                    }
                }
            }
        }
    }

    private func todoistTaskRow(_ task: TodoistTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                Task { await appState.completeTodoistTask(task) }
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.content).font(.callout)
                HStack(spacing: 6) {
                    if let projectName = projectName(for: task.projectId) {
                        Text(projectName).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let due = task.due {
                        Text(due.string).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(6)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func projectName(for projectId: String?) -> String? {
        guard let projectId else { return nil }
        return appState.todoistProjects.first { $0.id == projectId }?.name
    }

    // MARK: - 보낸 기록 탭

    @ViewBuilder
    private var historyTab: some View {
        if appState.sentTaskRecords.isEmpty {
            Spacer()
            Text("아직 보낸 기록이 없습니다.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.sentTaskRecords) { record in
                        historyRow(record)
                    }
                }
            }
        }
    }

    private func historyRow(_ record: SentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.text).font(.callout)
            HStack(spacing: 6) {
                if let name = record.sourceFileName {
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                }
                Text(record.sentAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
