import SwiftUI
import AppKit

/// 문제 풀기 화면 — 이미 만들어 둔 문제집(100제 등)을 눌러서 푼다.
/// mediaedu-quiz의 문제 화면을 그대로 옮겼다: 보기를 누르면 즉시 채점(정답 초록·내 오답 빨강·
/// 나머지 흐리게·잠금), 상단에 진행 통계와 막대, 형식 탭, 해설 접기, 하단에 전체/틀린 것만/다시 풀기.
///
/// 로직은 전부 `AppState+StudyQuiz`·`QuizImportParser`·`QuizRecordNote`에 있고 이 화면은 배선만 한다.
struct StudyQuizView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.quizOpenSource == nil {
                bookList
            } else {
                solving
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if appState.quizBooks.isEmpty { await appState.loadQuizBooks() }
        }
    }

    // MARK: - 문제집 고르기

    private var bookList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("문제집").font(.headline)
                    Text(appState.quizBooks.isEmpty ? "문제집을 찾는 중…"
                                                    : "\(appState.quizBooks.count)권")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("문제집 폴더 추가…") { addQuizFolder() }
                Button("다시 훑기") { Task { await appState.loadQuizBooks() } }
                    .disabled(appState.quizBusy)
                Button("닫기") { appState.closeStudyQuiz() }
            }
            if let error = appState.quizError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()

            if appState.quizBusy && appState.quizBooks.isEmpty {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.quizBooks) { book in
                            bookRow(book)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
    }

    private func bookRow(_ book: QuizBook) -> some View {
        Button {
            Task { await appState.openQuizBook(book.sourceURL) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.body)
                    Text(bookSubtitle(book)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if book.dueCount > 0 {
                    Text("\(book.dueCount)")
                        .font(.caption).bold().monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(appState.quizBusy)
    }

    private func bookSubtitle(_ book: QuizBook) -> String {
        guard book.isStarted else { return "\(book.itemCount)문항 · 아직 안 풂" }
        return "\(book.itemCount)문항 · 푼 것 \(book.solvedCount) · 오늘 볼 것 \(book.dueCount)"
    }

    /// 문제집이 있는 폴더 고르기 — 설정까지 가지 않아도 여기서 바로 등록한다.
    private func addQuizFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이 폴더 쓰기"
        panel.message = "문제집 마크다운이 들어 있는 폴더를 고르세요. 원본은 읽기만 하고 고치지 않습니다."
        if panel.runModal() == .OK, let url = panel.url {
            appState.registerQuizFolder(url)
        }
    }

    // MARK: - 푸는 화면

    private var solving: some View {
        VStack(alignment: .leading, spacing: 0) {
            solvingHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.visibleQuizItems) { item in
                        questionCard(item)
                    }
                    if appState.visibleQuizItems.isEmpty {
                        emptyNotice.padding(.top, 40)
                    }
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
    }

    private var solvingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.quizOpenSource?.deletingPathExtension().lastPathComponent ?? "문제집")
                        .font(.headline)
                    HStack(spacing: 8) {
                        stat("푼 문제", "\(appState.quizSolvedCount)/\(appState.quizItems.count)", .primary)
                        stat("맞음", "\(appState.quizCorrectCount)", .green)
                        stat("틀림", "\(appState.quizWrongCount)", .red)
                    }
                }
                Spacer()
                Button("문제집 목록") {
                    appState.closeQuizBook()
                    Task { await appState.loadQuizBooks() }
                }
                Button("닫기") { appState.closeStudyQuiz() }
            }
            ProgressView(value: progress).progressViewStyle(.linear)
            if let error = appState.quizError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            typeTabs
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private var progress: Double {
        guard !appState.quizItems.isEmpty else { return 0 }
        return Double(appState.quizSolvedCount) / Double(appState.quizItems.count)
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).bold().monospacedDigit().foregroundStyle(tint)
        }
    }

    private var typeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab("전체", filter: .all)
                tab("안 푼 것", filter: .unsolved)
                ForEach(appState.quizTypes, id: \.self) { name in
                    tab(name, filter: .type(name))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func tab(_ title: String, filter: QuizFilter) -> some View {
        let on = appState.quizFilter == filter
        return Button(title) { appState.quizFilter = filter }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.3)),
                        in: Capsule())
            .foregroundStyle(on ? Color.white : Color.primary)
    }

    @ViewBuilder
    private var emptyNotice: some View {
        VStack(spacing: 6) {
            switch appState.quizFilter {
            case .wrong:
                Text("틀린 문제가 없어요 🎉").font(.callout)
                Text("전체를 풀어보거나, 다 맞혔다면 축하해요.").font(.caption).foregroundStyle(.secondary)
            case .unsolved:
                Text("안 푼 문제가 없어요 🎉").font(.callout)
            default:
                Text("보여줄 문제가 없어요.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 문제 카드

    private func questionCard(_ item: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(item.n).").font(.body).bold().foregroundStyle(.tint)
                if !item.question.type.isEmpty {
                    Text(item.question.type)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                if item.state.lapses > 0 {
                    Text("전에 틀림 \(item.state.lapses)회")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(item.question.prompt).font(.body).textSelection(.enabled)

            VStack(spacing: 6) {
                ForEach(Array(item.question.options.enumerated()), id: \.offset) { index, option in
                    choiceButton(item: item, number: index + 1, text: option)
                }
            }

            if item.isSolved { afterAnswer(item) }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 보기 한 줄. 아직 안 골랐으면 누를 수 있고, 고른 뒤에는 잠긴 채 색으로 정답·오답을 보여준다.
    private func choiceButton(item: QuizItem, number: Int, text: String) -> some View {
        let solved = item.isSolved
        let isAnswer = number == item.answer
        let isPicked = number == item.picked
        return Button {
            Task { await appState.pickQuizChoice(itemNumber: item.n, choice: number) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.caption).bold().monospacedDigit()
                    .frame(width: 20, height: 20)
                    .background(markBackground(solved: solved, isAnswer: isAnswer, isPicked: isPicked),
                                in: Circle())
                    .foregroundStyle(solved && (isAnswer || isPicked) ? Color.white : Color.secondary)
                Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(solved: solved, isAnswer: isAnswer, isPicked: isPicked),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(solved && !isAnswer && !isPicked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(solved || appState.quizBusy)
    }

    private func markBackground(solved: Bool, isAnswer: Bool, isPicked: Bool) -> AnyShapeStyle {
        guard solved else { return AnyShapeStyle(.quaternary.opacity(0.4)) }
        if isAnswer { return AnyShapeStyle(Color.green) }
        if isPicked { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(.quaternary.opacity(0.4))
    }

    private func rowBackground(solved: Bool, isAnswer: Bool, isPicked: Bool) -> AnyShapeStyle {
        guard solved else { return AnyShapeStyle(.quaternary.opacity(0.25)) }
        if isAnswer { return AnyShapeStyle(Color.green.opacity(0.15)) }
        if isPicked { return AnyShapeStyle(Color.red.opacity(0.15)) }
        return AnyShapeStyle(.quaternary.opacity(0.15))
    }

    /// 채점 뒤에 뜨는 부분 — 판정 한 줄 + 해설 접기/펴기 + 교재 쪽 열기.
    private func afterAnswer(_ item: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.isCorrect ? "정답!" : "오답 — 정답은 \(item.answer)번")
                .font(.callout).bold()
                .foregroundStyle(item.isCorrect ? Color.green : Color.red)

            HStack(spacing: 7) {
                Button(item.explanationShown ? "해설 접기" : "해설 보기") {
                    appState.toggleQuizExplanation(itemNumber: item.n)
                }
                .font(.caption)
                if let page = StudySourceLink.page(of: item.question.locator) {
                    Button("📖 교재 \(page)쪽 열기") { appState.openQuizSource(itemNumber: item.n) }
                        .font(.caption)
                }
            }

            if item.explanationShown, !item.question.explanation.isEmpty {
                Text(item.question.explanation)
                    .font(.callout).textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // MARK: - 하단 바

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button("전체") { appState.quizFilter = .all }
            Button("틀린 것만 (\(appState.quizWrongCount))") { appState.quizFilter = .wrong }
                .disabled(appState.quizWrongCount == 0)
            Spacer()
            Button("이번 판 다시 풀기") { appState.restartQuizRound() }
                .disabled(appState.quizSolvedCount == 0)
                .help("화면의 정오 표시만 지웁니다. 복습 기록은 그대로 남습니다.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
