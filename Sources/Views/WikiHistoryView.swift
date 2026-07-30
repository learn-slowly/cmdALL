import SwiftUI

/// 위키 변경 기록 화면(계획 §이력 화면) — 인제스트 적용·되돌리기로 생긴 변화만 최신순으로
/// 보여준다. 앱에서 위키 글을 직접 열어 고쳐 저장한 것은 여기 안 남는다(AC 10, 정직한 한계).
struct WikiHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRowID: UUID?
    @State private var restoring = false

    private var selectedRow: WikiHistoryGrouping.Row? {
        appState.wikiHistoryRows.first { $0.id == selectedRowID }
    }

    var body: some View {
        HSplitView {
            listSection.frame(minWidth: 280, idealWidth: 320)
            detailSection.frame(minWidth: 380)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("닫기") { dismiss() }
            }
        }
        .task { await appState.loadWikiHistory() }
    }

    // MARK: - 목록

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                pageFilterPicker
                Spacer()
                Button {
                    Task { await appState.loadWikiHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새로고침 — 밖에서 파일이 바뀌었으면 눌러야 반영됩니다")
                .disabled(appState.wikiHistoryBusy)
            }
            .padding(12)

            Divider()

            if appState.wikiHistoryBusy && appState.wikiHistoryRows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.wikiHistoryRows.isEmpty {
                emptyState
            } else {
                List(appState.wikiHistoryRows, selection: $selectedRowID) { row in
                    rowLabel(row).tag(row.id as UUID?)
                }
            }
        }
    }

    private var pageFilterPicker: some View {
        Picker("글 고르기", selection: Binding(
            get: { appState.wikiHistoryPageFilter },
            set: { newValue in
                appState.wikiHistoryPageFilter = newValue
                Task { await appState.loadWikiHistory() }
            })) {
            Text("전체").tag(URL?.none)
            ForEach(appState.wikiHistoryKnownPages, id: \.self) { url in
                Text(url.lastPathComponent).tag(URL?.some(url))
            }
        }
        .frame(maxWidth: 220)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("아직 가져와서 합친 기록이 없습니다.")
                .font(.headline)
            Text("이 화면은 바깥 문서를 위키 글에 합친 기록과 그걸 되돌린 기록만 보여줍니다.\n앱에서 직접 고쳐 저장한 것은 여기에 남지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func rowLabel(_ row: WikiHistoryGrouping.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.entry.pageURL.lastPathComponent).font(.callout)
                if row.isRestoreEvent {
                    Text("되돌리기로 생긴 변화입니다")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
            }
            Text("\(row.entry.sourceName) · \(row.entry.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if appState.wikiHistoryLikelyEditedAfter(row) {
                Text("기록 이후에 직접 고쳐진 것 같습니다").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 상세(diff)

    @ViewBuilder
    private var detailSection: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.entry.pageURL.lastPathComponent).font(.headline)
                diffContent(row)
                Spacer(minLength: 0)
                if let error = appState.wikiIngestError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("되돌리기") {
                        guard !restoring else { return }
                        restoring = true
                        Task {
                            _ = await appState.restoreFromWikiHistory(row)
                            restoring = false
                        }
                    }
                    .disabled(restoring || row.diffState == .missingBackup)
                }
            }
            .padding(16)
        } else {
            Text("왼쪽에서 항목을 고르면 그때 달라진 부분을 볼 수 있습니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func diffContent(_ row: WikiHistoryGrouping.Row) -> some View {
        switch row.diffState {
        case .pair(let old, let new):
            WikiDiffListView(lines: LineDiff.diff(old: old, new: new))
        case .createdPage(let new):
            Text("이때 새로 만들어진 글입니다").font(.callout).foregroundStyle(.secondary)
            WikiDiffListView(lines: LineDiff.diff(old: "", new: new))
        case .legacyNoResult(let old):
            Text("예전 기록입니다 — 이때 정확히 무엇이 달라졌는지는 보여줄 수 없습니다.")
                .font(.callout).foregroundStyle(.secondary)
            if let old {
                DisclosureGroup("바뀌기 전 내용 보기") {
                    ScrollView {
                        Text(old)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                }
            }
        case .missingBackup:
            Text("이 시점의 내용을 찾지 못했습니다").font(.callout).foregroundStyle(.red)
        }
    }
}
