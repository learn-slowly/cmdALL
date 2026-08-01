import SwiftUI

/// "문서에서 할일 찾기" 화면 — 실제 로직은 `AppState+TaskFinder.swift`/`TaskFinderService`/
/// `TodoistService`에 있고, 이 화면은 배선만 부른다.
struct TaskFinderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let notice = appState.taskFinderAINotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let summary = appState.taskFinderSentSummary {
                Text(summary).font(.caption).foregroundStyle(.green)
            }
            if let error = appState.taskFinderError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 480, height: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("문서에서 할일 찾기").font(.headline)
                if let name = appState.taskFinderSourceURL?.lastPathComponent {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("닫기") { appState.closeTaskFinder() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.taskFinderBusy && appState.taskFinderCandidates.isEmpty {
            Spacer()
            ProgressView("찾는 중…")
            Spacer()
        } else if appState.taskFinderCandidates.isEmpty {
            Spacer()
            Text("찾은 할일이 없습니다.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.taskFinderCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: TaskCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { appState.taskFinderSelected.contains(candidate.id) },
                set: { _ in appState.toggleTaskFinderSelection(candidate.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.text).font(.callout)
                Text(candidate.source == .checkbox ? "체크박스" : "AI 추정")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
        }
        .padding(6)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Text("\(appState.taskFinderSelected.count)개 선택됨").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Todoist로 보내기") { Task { await appState.sendSelectedTasksToTodoist() } }
                .buttonStyle(.borderedProminent)
                .disabled(appState.taskFinderSelected.isEmpty || appState.taskFinderBusy)
        }
    }
}
