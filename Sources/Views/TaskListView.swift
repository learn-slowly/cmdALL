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
            if let done = appState.lastCompletedTodoistTask {
                Button("방금 완료한 것 되돌리기") { Task { await appState.undoLastTodoistCompletion() } }
                    .help("\"\(done.content)\"을(를) 다시 할일로 되돌립니다.")
            }
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
            // 레고 결정(2026-08-01): 간트차트는 오늘부터 6개월까지만. 그보다 먼 마감일은 날짜만,
            // 마감일 없는 할일은 제목만 아래 목록으로 따로 보여준다.
            let today = Date()
            let dated: [(task: TodoistTask, due: Date)] = appState.todoistTasks
                .compactMap { task in
                    guard let due = task.due?.parsedDate else { return nil }
                    return (task: task, due: due)
                }
                .sorted { $0.due < $1.due }
            let near = dated.filter { !GanttLayout.isBeyondHorizon(due: $0.due, today: today) }.map(\.task)
            let far = dated.filter { GanttLayout.isBeyondHorizon(due: $0.due, today: today) }.map(\.task)
            let undated = appState.todoistTasks.filter { $0.due?.parsedDate == nil }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if near.isEmpty {
                        Text("6개월 안에 마감인 할일이 없어 간트차트를 그릴 수 없습니다.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        GanttChartView(tasks: near, today: today) { task in
                            Task { await appState.completeTodoistTask(task) }
                        }
                    }
                    if !far.isEmpty {
                        plainSection(title: "6개월 뒤 이후 (\(far.count)개)", tasks: far, showsDate: true)
                    }
                    if !undated.isEmpty {
                        plainSection(title: "마감일 없음 (\(undated.count)개)", tasks: undated, showsDate: false)
                    }
                }
            }
        }
    }

    /// 간트차트에 안 들어가는 할일(먼 미래·마감일 없음)의 단순 목록. 막대 없이 제목만,
    /// 날짜가 있으면 오른쪽에 날짜만 붙인다.
    private func plainSection(title: String, tasks: [TodoistTask], showsDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(tasks) { task in
                plainRow(task, showsDate: showsDate)
            }
        }
    }

    private func plainRow(_ task: TodoistTask, showsDate: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await appState.completeTodoistTask(task) }
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)

            Text(task.content).font(.caption).lineLimit(1)
                .help(task.content)   // 긴 제목은 마우스를 올려야 전체가 보인다(다듬기 D).
            Spacer()
            if showsDate, let string = task.due?.string {
                Text(string).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
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
