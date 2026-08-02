import SwiftUI

/// 교재 진도 화면(`MainMode.progress`) — 레고 요청 2026-08-02 "교재 목차를 가지고 전체 진도
/// 관리". 왼쪽은 등록한 교재 목록, 오른쪽은 고른 교재의 진도 세 줄(읽음·만듦·익힘)과 목차 표.
/// 실제 계산·파일 쓰기는 `AppState+StudyProgress`와 순수 부품에 있고 여기선 그리기만 한다.
struct StudyProgressView: View {
    @Environment(AppState.self) private var appState

    /// "장 추가" 입력칸 상태(화면 안에서만 쓰는 값이라 AppState에 두지 않는다).
    @State private var newChapterTitle = ""
    @State private var newChapterStart = 1
    @State private var showAddChapter = false

    var body: some View {
        HStack(spacing: 0) {
            bookList
                .frame(width: 240)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await appState.loadStudyProgress() }
    }

    // MARK: - 왼쪽: 교재 목록

    private var bookList: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("교재").font(.headline)
                Spacer()
                Button {
                    appState.pickStudyProgressSource()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("교재 추가")
                .disabled(appState.studyProgressBusy)
            }

            if appState.studyProgressBooks.isEmpty {
                Text("아직 등록한 교재가 없습니다.\n＋로 교재를 더해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.studyProgressBooks) { book in
                        bookRow(book)
                    }
                    if !appState.studyProgressSuggestions.isEmpty {
                        suggestionSection
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func bookRow(_ book: StudyProgressBook) -> some View {
        Button {
            appState.studyProgressSelectedID = book.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.callout).lineLimit(2)
                    .help(book.sourceURL?.path ?? book.noteURL.path)
                miniBars(book.summary)
                if !book.sourceExists {
                    Text("교재 파일 없음").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(book.id == appState.studyProgressSelectedID ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func miniBars(_ summary: StudyProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            bar(ratio: summary.readRatio, color: .blue, height: 4)
            bar(ratio: summary.madeRatio, color: .purple, height: 4)
            bar(ratio: summary.masteredRatio, color: .green, height: 4)
        }
    }

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            Text("카드·문제를 만든 교재").font(.caption).foregroundStyle(.secondary)
            ForEach(appState.studyProgressSuggestions, id: \.self) { url in
                Button {
                    Task { await appState.prepareStudyProgressOutline(for: url) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.caption2)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("진도 관리에 추가: \(url.path)")
            }
        }
    }

    // MARK: - 오른쪽: 고른 교재

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = appState.studyProgressError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if appState.studyProgressPendingOutline != nil {
                pendingPreview
            } else if let book = appState.selectedStudyProgressBook {
                bookDetail(book)
            } else if appState.studyProgressBusy {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("왼쪽에서 교재를 고르거나, ＋로 교재를 더해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - 교재 등록 미리보기(제안 → 확인 → 실행)

    @ViewBuilder
    private var pendingPreview: some View {
        if let outline = appState.studyProgressPendingOutline,
           let source = appState.studyProgressPendingSource {
            VStack(alignment: .leading, spacing: 10) {
                Text("교재 등록 미리보기").font(.headline)
                Text(source.lastPathComponent).font(.callout)
                Text(appState.studyProgressPendingSourceLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Text("총 \(outline.total)\(outline.unit.label) · 장 \(outline.chapters.count)개")
                    .font(.caption)

                if !appState.studyProgressPendingTOC.isEmpty {
                    offsetRow
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outline.chapters) { chapter in
                            HStack(spacing: 6) {
                                Text("\(chapter.no).").font(.caption2).foregroundStyle(.secondary)
                                Text(chapter.title).font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(chapter.start)~\(chapter.end)\(outline.unit.label)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)

                HStack {
                    Text("등록을 눌러야 진도 노트가 만들어집니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("취소") { appState.cancelStudyProgressPending() }
                    Button("등록") { Task { await appState.confirmStudyProgressBook() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.studyProgressBusy)
                }
            }
        }
    }

    /// 쪽번호 보정 — 목차에 적힌 쪽과 실제 PDF 장이 어긋날 때 맞춘다(실측: 보통 −1).
    private var offsetRow: some View {
        HStack(spacing: 8) {
            Text("쪽 번호 맞추기").font(.caption)
            Button("−1") { appState.setStudyProgressPendingOffset(appState.studyProgressPendingOffset - 1) }
                .controlSize(.small)
            Text("\(appState.studyProgressPendingOffset > 0 ? "+" : "")\(appState.studyProgressPendingOffset)")
                .font(.caption).monospacedDigit().frame(width: 32)
            Button("+1") { appState.setStudyProgressPendingOffset(appState.studyProgressPendingOffset + 1) }
                .controlSize(.small)
            Text("목차의 첫 장이 실제 몇 번째 장에서 시작하는지 보고 맞추세요.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 등록된 교재 상세

    @ViewBuilder
    private func bookDetail(_ book: StudyProgressBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.headline)
                    Text("총 \(book.summary.total)\(book.summary.unit.label) · 장 \(book.summary.chapters.count)개 · 카드·문제 \(book.summary.itemCount)개")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("목차 다시 읽기") { Task { await appState.refreshStudyProgressOutline(bookID: book.id) } }
                    .disabled(appState.studyProgressBusy || !book.sourceExists)
                Button("노트 열기") { appState.openStudyProgressNote(bookID: book.id) }
                Button("장 추가…") { showAddChapter = true }
            }

            summaryBars(book.summary)

            if book.summary.unplacedItemCount > 0 {
                Text("카드·문제 \(book.summary.unplacedItemCount)개는 만든 위치가 적혀 있지 않아 어느 장에도 붙지 않았습니다(2026-08-02 이전에 만든 한글·워드 카드·문제 — 다시 만들면 장에 붙습니다).")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !book.sourceExists {
                Text("교재 파일을 찾지 못했습니다(옮겼거나 지웠을 수 있어요).")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()
            chapterTable(book)
        }
        .sheet(isPresented: $showAddChapter) {
            addChapterSheet(book)
        }
    }

    /// 세 줄 진도 막대 — 레고 결정 1: "전체 분량(목차) 대비 세 가지를 나란히".
    private func summaryBars(_ summary: StudyProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow(label: "읽음", ratio: summary.readRatio, color: .blue,
                       detail: "\(summary.readLength)/\(summary.total)\(summary.unit.label)")
            summaryRow(label: "만듦", ratio: summary.madeRatio, color: .purple,
                       detail: "\(summary.madeLength)/\(summary.total)\(summary.unit.label)")
            summaryRow(label: "익힘", ratio: summary.masteredRatio, color: .green,
                       detail: "\(summary.masteredItemCount)/\(summary.itemCount)개 익힘")
        }
    }

    private func summaryRow(label: String, ratio: Double, color: Color, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 32, alignment: .leading)
            bar(ratio: ratio, color: color, height: 10)
            Text("\(Int((ratio * 100).rounded()))%")
                .font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func bar(ratio: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, ratio)))
            }
        }
        .frame(height: height)
    }

    // MARK: - 목차 표

    private func chapterTable(_ book: StudyProgressBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(book.summary.chapters) { progress in
                    chapterRow(book, progress)
                }
            }
        }
    }

    private func chapterRow(_ book: StudyProgressBook, _ progress: StudyChapterProgress) -> some View {
        let chapter = progress.chapter
        return HStack(spacing: 8) {
            Button {
                Task {
                    await appState.toggleStudyProgressRead(bookID: book.id, chapterNo: chapter.no,
                                                           read: !chapter.read)
                }
            } label: {
                Image(systemName: chapter.read ? "checkmark.square.fill" : "square")
                    .foregroundStyle(chapter.read ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(chapter.read ? "읽음 표시 지우기" : "읽음으로 표시")

            Button {
                appState.openStudyProgressChapter(bookID: book.id, chapter: chapter)
            } label: {
                Text("\(chapter.no). \(chapter.title)")
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("교재의 이 부분 열기")

            Text("\(chapter.start)~\(chapter.end)\(book.summary.unit.label)")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(progress.itemCount > 0 ? "\(progress.itemCount)개" : "—")
                .font(.caption2).foregroundStyle(progress.itemCount > 0 ? .primary : .secondary)
                .frame(width: 40, alignment: .trailing)

            Text(progress.hasItems ? "\(Int((progress.masteryRatio * 100).rounded()))%" : "—")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 장 직접 추가(목차 없는 교재 — 레고 결정 2-b)

    private func addChapterSheet(_ book: StudyProgressBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("장 추가").font(.headline)
            Text("목차가 없는 교재는 장 이름과 시작 위치를 직접 적어 만들 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("장 이름", text: $newChapterTitle)
            HStack {
                Text("시작 \(book.summary.unit.label)")
                TextField("", value: $newChapterStart, format: .number)
                    .frame(width: 70)
                Text("(1~\(book.summary.total))").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("취소") { closeAddChapter() }
                Button("추가") {
                    let title = newChapterTitle
                    let start = newChapterStart
                    closeAddChapter()
                    Task { await appState.addStudyProgressChapter(bookID: book.id, title: title, start: start) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newChapterTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func closeAddChapter() {
        showAddChapter = false
        newChapterTitle = ""
        newChapterStart = 1
    }
}
