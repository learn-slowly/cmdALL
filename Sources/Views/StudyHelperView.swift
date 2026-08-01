import SwiftUI

/// 학습도우미(Study Helper) S1 전용 화면 — 파일 선택 → 미리 분량 표시 → 카드/문제 생성 →
/// 미리보기 → 저장까지 한 시트에서 이어 붙인다(계획서 File-level changes 참고). 실제 로직은
/// `StudySourceLoader`/`StudyChunker`/`StudyService`/`StudyNoteWriter`(순수·actor)에 있고
/// 이 화면은 `AppState+Study.swift` 배선만 부른다.
struct StudyHelperView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("학습도우미").font(.headline)
                Spacer()
                Button("닫기") { state.showStudyHelper = false }
            }
            Text("교재 파일 하나를 골라 정리 카드나 연습 문제를 만듭니다. 만들기 전에는 아무 파일도 생기지 않고, 저장을 눌러야만 노트가 생깁니다.")
                .font(.caption).foregroundStyle(.secondary)

            sourceRow
            optionsRow
            planLabel

            Divider()
            content
            Spacer()
        }
        .padding(16)
        .frame(width: 640, height: 620)
    }

    // MARK: - 파일 선택

    private var sourceRow: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            if let url = appState.studyScopeFileURL {
                Text(url.lastPathComponent).lineLimit(1)
            } else {
                Text("교재 파일을 선택하세요").foregroundStyle(.secondary)
            }
            Spacer()
            Button(appState.studyScopeFileURL == nil ? "파일 선택…" : "다른 파일…") {
                appState.pickStudySourceFile()
            }
            .disabled(appState.studyBusy)
        }
    }

    // MARK: - 카드/문제 · 개수

    private var optionsRow: some View {
        @Bindable var state = appState
        return HStack {
            Picker("만들 것", selection: $state.studyGenerationKind) {
                Text("정리 카드").tag(StudyItemKind.card)
                Text("연습 문제").tag(StudyItemKind.question)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(appState.studyBusy)

            Spacer()

            Stepper("개수: \(appState.studyRequestedCount)", value: $state.studyRequestedCount, in: 1...30)
                .disabled(appState.studyBusy)
        }
    }

    // MARK: - 사전 분량 표시(AC #9)

    @ViewBuilder private var planLabel: some View {
        if appState.studyScopeFileURL != nil {
            HStack {
                Text("보낼 분량 약 \(appState.studyPreviewCharCount)자 · 조각 \(appState.studyPreviewChunkCount)개")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("만들기") { Task { await appState.generateStudyItems() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.studyBusy || appState.studyPreviewChunkCount == 0)
            }
        }
    }

    // MARK: - 상태별 본문

    @ViewBuilder private var content: some View {
        if appState.studyBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude가 만드는 중… 몇 분 걸릴 수 있습니다.").foregroundStyle(.secondary)
            }
        } else if let error = appState.studyError {
            Text(error).foregroundStyle(.red)
        } else if !appState.studyPreviewCards.isEmpty {
            previewAndSave(count: appState.studyPreviewCards.count) {
                cardList
            }
        } else if !appState.studyPreviewQuestions.isEmpty {
            previewAndSave(count: appState.studyPreviewQuestions.count) {
                questionList
            }
        } else {
            Text("파일을 고르고 \"만들기\"를 누르면 여기에 미리보기가 뜹니다.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewAndSave<Content: View>(count: Int, @ViewBuilder list: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = appState.studyOutcomeSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView { list() }
            HStack {
                Spacer()
                if let savedURL = appState.studySavedNoteURL {
                    Text("저장됨: \(savedURL.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                    Button("노트 열기") { appState.openSavedStudyNote() }
                } else {
                    Button("노트로 저장(\(count)개)") { Task { await appState.saveStudyNote() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var cardList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(appState.studyPreviewCards.enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).bold()
                    ForEach(Array(card.bullets.enumerated()), id: \.offset) { _, bullet in
                        Text("- \(bullet)").font(.callout)
                    }
                    Text("근거: \"\(card.quote)\"").font(.caption).foregroundStyle(.secondary)
                        .italic(card.unverifiedQuote)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(appState.studyPreviewQuestions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1). \(question.title)").bold()
                    Text(question.prompt).font(.callout)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Text("\(optionIndex + 1)) \(option)").font(.callout)
                    }
                    Text("정답: \(question.answer) · \(question.explanation)").font(.caption)
                    Text("근거: \"\(question.quote)\"").font(.caption).foregroundStyle(.secondary)
                        .italic(question.unverifiedQuote)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
