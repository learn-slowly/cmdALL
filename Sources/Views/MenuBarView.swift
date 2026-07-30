import SwiftUI

/// Menu-bar extra content: quick capture plus shortcuts into the main app.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: MenuBarViewMode = .capture
    @State private var searchText: String = ""

    private var activeDrafts: [Draft] {
        appState.drafts.filter { $0.status == .active }
    }

    /// 제목·본문 부분 일치 검색 — 사이드바 Drafts 탭과 달리 여기는 메뉴바 팝오버 안에서
    /// 바로 지난 메모를 찾아볼 수 있어야 한다(사용자 요청, 2026-07-30).
    private var filteredDrafts: [Draft] {
        guard !searchText.isEmpty else { return activeDrafts }
        return activeDrafts.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(MenuBarViewMode.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch mode {
            case .capture:
                QuickCaptureView()
            case .drafts:
                draftsList
            }

            Divider()

            HStack {
                Button {
                    appState.presentMainWindowIfNeeded()
                } label: {
                    Label("Open cmdALL", systemImage: "macwindow")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("\(appState.drafts.count) drafts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private var draftsList: some View {
        VStack(spacing: 0) {
            TextField("메모 검색…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            if filteredDrafts.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "저장된 메모 없음" : "찾는 메모 없음", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? "퀵 캡처에서 \"임시 메모로 저장\"하면 여기 쌓여요." : "다른 검색어로 찾아보세요.")
                }
                .frame(height: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredDrafts) { draft in
                            DraftRow(draft: draft)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.openDraft(draft)
                                    appState.presentMainWindowIfNeeded()
                                }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 360)
    }
}

/// 퀵 캡처 팝오버 상단 전환 — 새로 쓰기 ↔ 지난 메모 훑어보기(사용자 요청, 2026-07-30).
enum MenuBarViewMode: CaseIterable {
    case capture
    case drafts

    var title: String {
        switch self {
        case .capture: return "새 메모"
        case .drafts: return "지난 메모"
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environment(AppState())
}
#endif
