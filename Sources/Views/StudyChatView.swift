import SwiftUI

/// 학습도우미 대화(S3) 화면 — 학습도우미(S1)에서 고른 범위를 핀 발췌로 삼아 계속 대화한다.
/// 실제 로직은 `AppState+StudyChat.swift`/`StudyChatService`에 있고, 이 화면은 배선만 부른다.
/// 크래시 대비 임시 저장(복구 시트)은 이번 슬라이스 범위 밖 — 화면을 닫으면 대화는 사라진다.
struct StudyChatView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 10) {
            header
            if let notice = appState.studyChatNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let error = appState.studyChatError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            transcript
            Divider()
            inputRow
        }
        .padding(16)
        .frame(width: 560, height: 640)
        .onAppear { inputFocused = true }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("대화하며 공부하기").font(.headline)
                if let name = appState.studyChatSession?.sourceURL?.lastPathComponent {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let savedURL = appState.studyChatSavedNoteURL {
                Text("저장됨: \(savedURL.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                Button("노트 열기") { appState.openSavedStudyChatNote() }
            } else {
                Button("노트로 남기기") { Task { await appState.saveStudyChatAsNote() } }
                    .disabled(appState.studyChatSession?.turns.isEmpty ?? true)
            }
            Button("닫기") { appState.closeStudyChat() }
        }
    }

    // MARK: - 턴 목록

    @ViewBuilder
    private var transcript: some View {
        if let session = appState.studyChatSession {
            if session.turns.isEmpty {
                Text("교재 내용을 바탕으로 질문해 보세요. 답은 [핀 발췌]에 있는 부분만 근거로 삼습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                                turnBubble(turn).id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: session.turns.count) { _, _ in
                        proxy.scrollTo(session.turns.count - 1, anchor: .bottom)
                    }
                }
            }
        } else if appState.studyChatBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("교재를 읽는 중…").foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            Spacer()
        }
    }

    private func turnBubble(_ turn: StudyChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.role == .user ? "나" : "도우미")
                .font(.caption).bold().foregroundStyle(.secondary)
            Text(turn.text.isEmpty ? "…" : turn.text)
                .textSelection(.enabled)
            if turn.truncated {
                Text("(길어서 일부만 보냈어요)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (turn.role == .user ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 입력줄

    private var inputRow: some View {
        @Bindable var state = appState
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("질문을 입력하세요…", text: $state.studyChatText, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .disabled(appState.studyChatSession == nil)
                .onSubmit { Task { await appState.sendStudyChatMessage() } }

            if appState.studyChatBusy {
                Button("중단") { appState.stopStudyChat() }
            } else {
                Button("보내기") { Task { await appState.sendStudyChatMessage() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.studyChatSession == nil
                        || appState.studyChatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
