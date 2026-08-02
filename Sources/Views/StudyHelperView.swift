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
                Button("닫기") {
                    // 만들던 중에 닫으면 claude 호출도 같이 끊는다(유휴면 무동작).
                    appState.cancelStudyGeneration()
                    state.showStudyHelper = false
                }
            }
            Text("교재 파일 하나를 골라 정리 카드나 연습 문제를 만듭니다. 만들기 전에는 아무 파일도 생기지 않고, 저장을 눌러야만 노트가 생깁니다.")
                .font(.caption).foregroundStyle(.secondary)

            sourceRow
            rangeRow
            optionsRow
            planLabel

            Divider()
            content
            Spacer()
        }
        .padding(16)
        .frame(width: 640, height: 620)
        .sheet(isPresented: $state.showStudyTemplateManager) {
            StudyTemplateManagerView()
        }
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
            if appState.studyScopeFileURL != nil {
                Button("대화하며 공부하기") { appState.startStudyChat() }
                    .disabled(appState.studyBusy)
            }
            Button(appState.studyScopeFileURL == nil ? "파일 선택…" : "다른 파일…") {
                appState.pickStudySourceFile()
            }
            .disabled(appState.studyBusy)
        }
    }

    // MARK: - 부분 범위 선택(레고 2026-08-01 피드백 — "교재 전체를 한 번에 넣는 건 비현실적")

    private var rangeRow: some View {
        @Bindable var state = appState
        return Group {
            if let kind = appState.studyScopeKind, kind != .image {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("전체 파일 사용", isOn: $state.studyUseWholeFile)
                        .disabled(appState.studyBusy)
                        .onChange(of: state.studyUseWholeFile) { _, _ in
                            Task { await appState.updateStudyPreviewPlan() }
                        }

                    if !appState.studyUseWholeFile {
                        partialRangePicker(kind: kind)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func partialRangePicker(kind: DocumentKind) -> some View {
        switch kind {
        case .pdf:
            if appState.studyPDFPageCount > 0 {
                pageRangePicker
            }
        case .markdown:
            if appState.studyHeadingChoices.isEmpty {
                Text("이 파일엔 제목(#)이 없어 부분만 고를 수 없습니다 — 전체로 만듭니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                headingRangePicker
            }
        case .office:
            if appState.studyRangeLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("구간 목록 불러오는 중…").font(.caption).foregroundStyle(.secondary)
                }
            } else if appState.studySectionChoices.count <= 1 {
                Text("이 문서엔 제목 구간이 하나뿐이라 부분만 고를 수 없습니다 — 전체로 만듭니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                sectionRangePicker
            }
        default:
            EmptyView()
        }
    }

    private var pageRangePicker: some View {
        @Bindable var state = appState
        return HStack {
            Text("전체 \(appState.studyPDFPageCount)쪽 중").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $state.studyPageRangeStart, format: .number)
                .frame(width: 48)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .onChange(of: state.studyPageRangeStart) { _, _ in
                    appState.clampStudyPageRange(changed: .start)
                    Task { await appState.updateStudyPreviewPlan() }
                }
            Text("쪽부터")
            Text("~")
            TextField("", value: $state.studyPageRangeEnd, format: .number)
                .frame(width: 48)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .onChange(of: state.studyPageRangeEnd) { _, _ in
                    appState.clampStudyPageRange(changed: .end)
                    Task { await appState.updateStudyPreviewPlan() }
                }
            Text("쪽까지")
        }
        .font(.caption)
    }

    private var headingRangePicker: some View {
        @Bindable var state = appState
        return HStack {
            Text("시작").font(.caption).foregroundStyle(.secondary)
            Picker("시작", selection: $state.studyHeadingRangeStartIndex) {
                ForEach(Array(appState.studyHeadingChoices.enumerated()), id: \.offset) { index, choice in
                    Text(choice.title).tag(index)
                }
            }
            .labelsHidden()
            .onChange(of: state.studyHeadingRangeStartIndex) { _, newValue in
                if state.studyHeadingRangeEndIndex < newValue { state.studyHeadingRangeEndIndex = newValue }
                Task { await appState.updateStudyPreviewPlan() }
            }
            Text("~")
            Text("끝").font(.caption).foregroundStyle(.secondary)
            Picker("끝", selection: $state.studyHeadingRangeEndIndex) {
                ForEach(Array(appState.studyHeadingChoices.enumerated()), id: \.offset) { index, choice in
                    Text(choice.title).tag(index)
                }
            }
            .labelsHidden()
            .onChange(of: state.studyHeadingRangeEndIndex) { _, newValue in
                if state.studyHeadingRangeStartIndex > newValue { state.studyHeadingRangeStartIndex = newValue }
                Task { await appState.updateStudyPreviewPlan() }
            }
        }
        .font(.caption)
    }

    private var sectionRangePicker: some View {
        @Bindable var state = appState
        return HStack {
            Text("시작").font(.caption).foregroundStyle(.secondary)
            Picker("시작", selection: $state.studySectionRangeStart) {
                ForEach(appState.studySectionChoices) { choice in
                    Text(choice.title).tag(choice.index)
                }
            }
            .labelsHidden()
            .onChange(of: state.studySectionRangeStart) { _, newValue in
                if state.studySectionRangeEnd < newValue { state.studySectionRangeEnd = newValue }
                Task { await appState.updateStudyPreviewPlan() }
            }
            Text("~")
            Text("끝").font(.caption).foregroundStyle(.secondary)
            Picker("끝", selection: $state.studySectionRangeEnd) {
                ForEach(appState.studySectionChoices) { choice in
                    Text(choice.title).tag(choice.index)
                }
            }
            .labelsHidden()
            .onChange(of: state.studySectionRangeEnd) { _, newValue in
                if state.studySectionRangeStart > newValue { state.studySectionRangeStart = newValue }
                Task { await appState.updateStudyPreviewPlan() }
            }
        }
        .font(.caption)
    }
    // MARK: - 카드/문제 · 개수 · 템플릿(레고 2026-08-01 요청)

    private var optionsRow: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("만들 것", selection: $state.studyGenerationKind) {
                    Text("정리 카드").tag(StudyItemKind.card)
                    Text("연습 문제").tag(StudyItemKind.question)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(appState.studyBusy) // 종류 전환 시 템플릿 선택 초기화는 AppState.studyGenerationKind didSet이 처리.

                Spacer()

                Stepper("개수: \(appState.studyRequestedCount)", value: $state.studyRequestedCount, in: 1...50)
                    .disabled(appState.studyBusy)
            }

            HStack {
                Picker("템플릿", selection: $state.studySelectedTemplateID) {
                    Text("기본").tag(UUID?.none)
                    ForEach(appState.studyTemplates(for: appState.studyGenerationKind)) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
                .disabled(appState.studyBusy)

                Button("템플릿 관리…") { state.showStudyTemplateManager = true }
                    .disabled(appState.studyBusy)
            }
            .font(.caption)
        }
    }

    // MARK: - 사전 분량 표시(AC #9)

    @ViewBuilder private var planLabel: some View {
        if appState.studyScopeFileURL != nil {
            HStack {
                Text("보낼 분량 약 \(appState.studyPreviewCharCount)자 · 조각 \(appState.studyPreviewChunkCount)개")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if appState.studyBusy {
                    Button("취소") { appState.cancelStudyGeneration() }
                        .help("만들던 것을 멈춥니다. 지금까지 만든 건 저장되지 않습니다.")
                } else {
                    Button("만들기") { appState.startStudyGeneration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.studyPreviewChunkCount == 0)
                }
            }
        }
    }

    // MARK: - 상태별 본문

    @ViewBuilder private var content: some View {
        if appState.studyBusy {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude가 만드는 중… 몇 분 걸릴 수 있습니다.").foregroundStyle(.secondary)
                }
                if let progress = appState.studyProgress {
                    ProgressView(value: appState.studyProgressFraction)
                        .progressViewStyle(.linear)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
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
