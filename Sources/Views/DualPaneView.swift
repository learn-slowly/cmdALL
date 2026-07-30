import SwiftUI

// MARK: - DualPaneView

/// 두 폴더 나란히 보기(듀얼 페인, 로드맵 C/F4) — 화면 오른쪽을 좌우 두 칸으로 가른다.
/// 한 칸 모드(`MainEditorView`)는 이 파일과 무관하게 그대로 동작한다(설계 §3.1).
struct DualPaneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            if appState.panes.indices.contains(0) {
                PaneView(index: 0)
            }
            Divider()
            if appState.panes.indices.contains(1) {
                PaneView(index: 1)
            }
        }
    }
}

// MARK: - PaneView

/// 칸 하나 — 경로 표시 + 폴더 목록. 파일 클릭 시 읽기 전용 미리보기는 Task 5에서 추가된다.
struct PaneView: View {
    @Environment(AppState.self) private var appState
    let index: Int

    /// 렌더 시점 스냅샷(값 타입) — 존재하지 않으면 빈 화면.
    private var pane: BrowsePane? {
        appState.panes.indices.contains(index) ? appState.panes[index] : nil
    }

    private var isFocused: Bool { appState.focusedPaneIndex == index }

    /// 폴더가 바뀔 때만 재열거하기 위한 키(LibraryView와 동일 관례).
    private var folderKey: String {
        "\(pane?.selectedFolder.path ?? "∅")|\(appState.settings.showHiddenFiles)"
    }

    @State private var entries: [FileTreeItem] = []
    /// 드롭 대상 하이라이트(폴더 행에 파일을 끌고 올 때).
    @State private var dropTargetURL: URL? = nil

    var body: some View {
        if let peekFile = pane?.peekFile {
            PaneReaderView(paneIndex: index, url: peekFile)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if isFocused {
                        Rectangle().fill(Color.cmdsAccent).frame(height: 2)
                    }
                }
                .id(peekFile)
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                list
            }
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if isFocused {
                    Rectangle().fill(Color.cmdsAccent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.focusPane(index) }
            .task(id: folderKey) { reloadEntries() }
        }
    }

    private func reloadEntries() {
        guard let pane else { entries = []; return }
        let items = LibraryListing.entries(of: pane.selectedFolder, showHidden: appState.settings.showHiddenFiles)
        entries = LibrarySorting.sorted(items, by: pane.sort, under: pane.rootFolder)
    }

    // MARK: - 헤더(경로 표시 — 칸 전용 최소 버전, 전역 PathBarView와 별개)

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                appState.goUpInPane(index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(pane == nil || pane?.selectedFolder == pane?.rootFolder)
            .help("상위 폴더")

            Text(pane?.selectedFolder.lastPathComponent ?? "")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - 목록

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("이 폴더에 항목이 없습니다", systemImage: "folder")
            }
        } else {
            List(entries, id: \.url) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.cmdsAccent : .secondary)
                    Text(item.url.lastPathComponent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .background(dropTargetURL == item.url ? Color.cmdsAccent.opacity(0.15) : .clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard item.isDirectory else { return }
                    appState.openFolder(inPane: index, url: item.url)
                }
                .onTapGesture {
                    appState.focusPane(index)
                    if !item.isDirectory {
                        appState.openPeekFile(item.url, in: index)
                    }
                }
                .onDrop(of: FileDropDelegate.acceptedTypes,
                        delegate: FileDropDelegate(
                            destination: item.isDirectory ? item.url : (pane?.selectedFolder ?? item.url),
                            appState: appState,
                            onHoverChange: { dropTargetURL = $0 ? item.url : nil }))
            }
            .listStyle(.plain)
            // 빈 자리(행 사이·목록 배경)로의 드롭 — 이 칸이 지금 보여주는 폴더로 이동(F2 재사용).
            .onDrop(of: FileDropDelegate.acceptedTypes,
                    delegate: FileDropDelegate(destination: pane?.selectedFolder ?? URL(fileURLWithPath: "/"),
                                               appState: appState))
        }
    }
}

// MARK: - 툴바 토글 버튼

/// 두 칸 보기 켜고 끄기(설계 §3.1, 사용자 결정 1 — 버튼 토글).
struct DualPaneToggleButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.toggleDualPane()
        } label: {
            // 채워진 모양 — 리더 화면의 "분할 보기"(rectangle.split.2x1, 테두리만)와
            // 아이콘이 완전히 같아 혼동된다는 사용자 지적(2026-07-30)으로 구분.
            Image(systemName: "rectangle.split.2x1.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appState.dualPaneEnabled ? Color.cmdsAccent : .primary)
        .help("두 폴더 나란히 보기")
    }
}
