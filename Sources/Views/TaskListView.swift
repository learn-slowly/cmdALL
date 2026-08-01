import SwiftUI

/// "할일 목록" — Todoist 실시간 할일(간트차트) + 이 앱이 문서에서 찾아 Todoist로 보낸 기록,
/// 두 탭. 레고 요청(2026-08-01 "이걸 파일 화면 보듯이 해줘")으로 팝업 시트가 아니라
/// 파일 화면(리더·라이브러리)과 같은 **메인 창 전체 모드**(`MainMode.tasks`)로 들어간다.
/// 실제 로직은 `AppState+TaskList.swift`/`TodoistService`/`SentTaskLogStore`에 있고,
/// 이 화면은 배선만 부른다.
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
            .frame(maxWidth: 320, alignment: .leading)

            if appState.taskListSelectedTab == .todoist {
                todoistTab
            } else {
                historyTab
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 파일 화면과 같은 진입 감각 — 모드로 들어올 때마다 최신 상태를 한 번 불러온다.
        .task { await appState.loadTaskListData() }
    }

    private var header: some View {
        HStack {
            Text("할일 목록").font(.headline)
            Spacer()
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
            let dated = appState.todoistTasks
                .filter { $0.due?.parsedDate != nil }
                .sorted { $0.due!.parsedDate! < $1.due!.parsedDate! }
            let undatedCount = appState.todoistTasks.count - dated.count
            if dated.isEmpty {
                Spacer()
                Text("마감일이 있는 할일이 없어 간트차트를 그릴 수 없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                GanttChartView(tasks: dated, today: Date()) { task in
                    Task { await appState.completeTodoistTask(task) }
                }
                if undatedCount > 0 {
                    Text("마감일 없는 할일 \(undatedCount)개는 표시되지 않습니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
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
