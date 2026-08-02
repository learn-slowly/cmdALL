import SwiftUI

/// 오늘 복습(S2) 화면 — 실제 로직은 전부 `AppState+StudyReview.swift`/`ReviewScheduler`/
/// `StudyNoteParser`/`StudyIndex`에 있고, 이 화면은 배선만 부른다.
struct StudyReviewView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 10) {
            header
            if let notice = appState.studyReviewRebuildNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let error = appState.studyReviewError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await appState.openStudyReview() }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("오늘 복습").font(.headline)
                Text(progressLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("되돌리기") { Task { await appState.undoLastStudyReviewGrade() } }
                .disabled(appState.studyReviewBusy || appState.studyReviewUndo == nil)
                .keyboardShortcut("z", modifiers: .command)
                .help("방금 매긴 채점을 되돌립니다 (⌘Z)")
            Button("다시 훑기") { Task { await appState.refreshStudyReview() } }
                .disabled(appState.studyReviewBusy)
            Button("닫기") { appState.closeStudyReview() }
        }
    }

    private var progressLabel: String {
        let total = appState.studyReviewQueue.count
        guard total > 0 else { return "복습할 항목 없음" }
        let position = min(appState.studyReviewIndex + 1, total)
        return "\(position)/\(total)"
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        if appState.studyReviewBusy && appState.studyReviewQueue.isEmpty {
            Spacer()
            ProgressView()
            Spacer()
        } else if let item = appState.currentStudyReviewItem {
            itemCard(item)
        } else {
            Spacer()
            VStack(spacing: 6) {
                Text("오늘 복습할 항목이 없습니다 🎉").font(.callout)
                Text("새로 만든 카드·문제가 있으면 \"다시 훑기\"를 눌러 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func itemCard(_ item: StudyIndexItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.kind == .card ? "카드" : "문제")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Button("원본 보기") { appState.openCurrentStudyReviewSource() }
                    .font(.caption)
                Button("노트 열기") { appState.openCurrentStudyReviewNote() }
                    .font(.caption)
            }
            Text(item.title).font(.title3).bold()

            if appState.studyReviewRevealAnswer {
                ScrollView {
                    Text(item.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                gradingRow
            } else {
                Spacer()
                Button("정답/전체 보기  (스페이스)") { appState.revealStudyReviewAnswer() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.space, modifiers: [])
                Spacer()
            }
        }
        .disabled(appState.studyReviewBusy)
    }

    private var gradingRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                gradeButton("모름", outcome: .forgot, tint: .red, key: "1")
                gradeButton("애매", outcome: .unsure, tint: .orange, key: "2")
                gradeButton("앎", outcome: .knew, tint: .green, key: "3")
            }
            Text("키보드: 1 모름 · 2 애매 · 3 앎 · ⌘Z 되돌리기")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 채점 버튼 — 숫자키 하나로도 눌린다(다듬기 A, 레고 2026-08-02 "키보드로 채점").
    private func gradeButton(_ title: String, outcome: ReviewOutcome, tint: Color,
                             key: KeyEquivalent) -> some View {
        Button("\(title) (\(String(key.character)))") {
            Task { await appState.gradeCurrentStudyReviewItem(outcome) }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .frame(maxWidth: .infinity)
        .keyboardShortcut(key, modifiers: [])
    }
}
