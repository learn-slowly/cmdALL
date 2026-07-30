import SwiftUI

/// ⇧⌘O everything-search: fuzzy file-name matching over the note index
/// (open folder + registered vaults, recents boosted) plus live full-text
/// matches from the open folder. Enter opens the hit — content matches jump
/// straight to the matched line.
/// Reference-type state — the ↑/↓ key monitor is an escaping closure, and mutating
/// @State through a captured View value won't re-render; an @Observable object does.
@Observable final class OmnisearchModel {
    var query = ""
    var selectedIndex = 0
    var navigatingByKeyboard = false
    var contentResults: [IndexHit] = []
    var isSearchingContent = false
    var sort = OmnisearchSort.default
}

struct OmnisearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// 전역 오버레이 패널(⌘⇧8)에서 재사용할 때만 채워진다 — 시트로 쓸 땐 nil이라
    /// `dismiss()`만으로 충분하다(전역 오버레이는 시트가 아니라 독립 NSPanel이라
    /// SwiftUI dismiss가 안 먹혀 별도 닫기 훅이 필요, GlobalSearchOverlayController 참고).
    var onRequestClose: (() -> Void)? = nil

    @State private var model = OmnisearchModel()
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var columnWidths = OmnisearchColumnWidths()

    // MARK: Hit assembly

    private var fileHits: [OmnisearchHit] {
        let builtHits: [OmnisearchHit]
        if model.query.isEmpty {
            // Bare ⇧⌘O = recent files, most useful default.
            builtHits = appState.recentFiles.prefix(8).map { url in
                let info = FileInfoService.loadBasic(url: url)
                return OmnisearchHit(
                    kind: .file,
                    title: url.deletingPathExtension().lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    url: url,
                    line: nil,
                    sizeBytes: info.sizeBytes,
                    modifiedAt: info.modifiedAt
                )
            }
        } else {
            let lowered = model.query.lowercased()
            let recents = Set(appState.recentFiles)

            builtHits = appState.linkableNotes
                .compactMap { note -> (VaultNote, Int)? in
                    let score = Command.fuzzyScore(query: lowered, in: note.title.lowercased())
                        ?? Command.fuzzyScore(query: lowered, in: note.path.lowercased())
                    guard var score else { return nil }
                    if recents.contains(note.url) { score += 20 }
                    return (note, score)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.modifiedAt > rhs.0.modifiedAt
                }
                .prefix(10)
                .map { note, _ in
                    let info = FileInfoService.loadBasic(url: note.url)
                    return OmnisearchHit(
                        kind: .file,
                        title: note.title,
                        subtitle: note.path,
                        url: note.url,
                        line: nil,
                        sizeBytes: info.sizeBytes,
                        modifiedAt: info.modifiedAt
                    )
                }
        }

        return OmnisearchHitSorting.sorted(builtHits, by: model.sort)
    }

    private var contentHits: [OmnisearchHit] {
        model.contentResults.prefix(12).map { hit in
            OmnisearchHit(
                kind: .content,
                title: (hit.path as NSString).lastPathComponent,
                subtitle: hit.snippet.isEmpty ? hit.path : hit.snippet,
                url: URL(fileURLWithPath: hit.path),
                line: nil
            )
        }
    }

    private var allHits: [OmnisearchHit] {
        fileHits + contentHits
    }

    // MARK: Body

    var body: some View {
        @Bindable var model = model
        let hits = allHits

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.cmdsAccent)

                PaletteTextField(
                    text: $model.query,
                    placeholder: "Search file names and contents…",
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onSubmit: { open(at: model.selectedIndex, in: allHits) },
                    onCancel: { dismiss(); onRequestClose?() }
                )
                .frame(height: 24)

                if model.isSearchingContent {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("ESC")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()
            .background(.bar)

            Divider()

            if hits.isEmpty {
                // ContentUnavailableView는 주어진 공간 전체를 세로 가운데 정렬해 위에 큰 빈
                // 공간이 생긴다(레고님 지적) — PaneReaderView.summaryPlaceholder와 동일 원인·
                // 동일 수정: 직접 조립한 VStack + alignment: .top으로 위쪽에 붙인다.
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "No Recent Files" : "No Matches")
                        .font(.title3.weight(.semibold))
                    Text(model.query.isEmpty
                         ? "Open a folder or some files first — they get indexed for search."
                         : "No file names or contents match \"\(model.query)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            let fileCount = fileHits.count
                            if fileCount > 0 {
                                OmnisearchSectionHeader(title: model.query.isEmpty ? "Recent" : "Files")
                                OmnisearchColumnHeader(sort: $model.sort, columnWidths: $columnWidths)
                            }
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                if index == fileCount && !contentHits.isEmpty {
                                    OmnisearchSectionHeader(title: "In-file Matches")
                                }
                                Group {
                                    if hit.kind == .file {
                                        OmnisearchFileRow(hit: hit, isSelected: index == model.selectedIndex, columnWidths: columnWidths)
                                    } else {
                                        OmnisearchRow(hit: hit, isSelected: index == model.selectedIndex)
                                    }
                                }
                                    .id(index)
                                    .onHover { hovering in
                                        if hovering {
                                            model.navigatingByKeyboard = false
                                            model.selectedIndex = index
                                        }
                                    }
                                    .onTapGesture {
                                        open(at: index, in: hits)
                                    }
                                    .onDrag {
                                        // 다른 앱/데스크탑으로 바로 끌어다 놓기(Docufinder 격차 4번) —
                                        // Finder는 fileURL 표현만 읽는다(DragPayload 주석 참고).
                                        appState.draggingURLs = [hit.url]
                                        return DragPayload.makeProvider(for: [hit.url], primary: hit.url)
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, newIndex in
                        guard model.navigatingByKeyboard else { return }
                        withAnimation(.easeInOut(duration: 0.13)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label("\(appState.linkableNotes.count) notes indexed", systemImage: "tray.full")
                if appState.currentFolder == nil && appState.settings.indexedFolders.isEmpty {
                    Text("Open a folder (⌥⌘O) to enable search")
                } else if appState.indexInProgress, let p = appState.indexProgress {
                    Text(p.total > 0 ? "훑는 중… (\(p.done)/\(p.total))" : "훑는 중…")
                }
                Spacer()
                Text("↩ open · ↑↓ navigate")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 760, height: 480)
        .tint(.cmdsAccent)
        .cmdOverlayChrome()
        .onDisappear {
            contentSearchTask?.cancel()
        }
        .onChange(of: model.query) { _, newQuery in
            model.selectedIndex = 0
            scheduleContentSearch(for: newQuery)
        }
    }

    /// Moves the highlight by `delta`, clamped to the hit list.
    private func moveSelection(_ delta: Int) {
        let count = allHits.count
        guard count > 0 else { return }
        model.navigatingByKeyboard = true
        model.selectedIndex = min(max(model.selectedIndex + delta, 0), count - 1)
    }

    // MARK: Actions

    private func open(at index: Int, in hits: [OmnisearchHit]) {
        guard index >= 0, index < hits.count else { return }
        let hit = hits[index]
        dismiss()
        onRequestClose?()
        appState.openDocument(at: hit.url, inNewTab: true, scrollToLine: hit.line)
        // 오버레이 경로에서 파일을 열 땐 cmdALL이 아직 앞에 나서 있지 않다(⌘⇧8는
        // nonactivatingPanel이라 앱을 활성화하지 않음) — 시트 경로에선 이미 최상단이라 no-op.
        appState.presentMainWindowIfNeeded()
    }

    /// Debounced full-text search over the open folder. File-name hits update
    /// instantly; content hits stream in ~250ms after typing pauses.
    private func scheduleContentSearch(for query: String) {
        contentSearchTask?.cancel()
        model.contentResults = []

        // 색인(자동으로 훑어둔 폴더·볼트)이 하나라도 있으면 내용 검색 가능 — currentFolder가
        // nil이어도(볼트만 연결된 상태 등) 검색은 된다.
        guard query.count >= 2, !appState.settings.indexedFolders.isEmpty else {
            model.isSearchingContent = false
            return
        }

        model.isSearchingContent = true
        contentSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = await appState.searchContent(query: query)
            guard !Task.isCancelled else { return }
            model.contentResults = results
            model.isSearchingContent = false
        }
    }
}

private struct OmnisearchSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
/// 이름/경로/크기/수정일 칼럼 헤더 — 클릭 시 그 기준으로 정렬(`LibraryView.sortHeaderButton`과 같은 모양, 스펙 §5.4).
private struct OmnisearchColumnHeader: View {
    @Binding var sort: OmnisearchSort
    @Binding var columnWidths: OmnisearchColumnWidths

    var body: some View {
        HStack(spacing: 8) {
            sortButton(title: "이름", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            sortButton(title: "경로", key: .path)
                .frame(width: columnWidths.path, alignment: .leading)
                .contentShape(Rectangle())
            OmnisearchColumnResizeHandle(width: $columnWidths.path)
            sortButton(title: "크기", key: .size)
                .frame(width: columnWidths.size, alignment: .trailing)
                .contentShape(Rectangle())
            OmnisearchColumnResizeHandle(width: $columnWidths.size)
            sortButton(title: "수정일", key: .modifiedAt)
                .frame(width: columnWidths.modifiedAt, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    /// 헤더 버튼 — 클릭=키 선택, 같은 키 재클릭=방향 토글(`OmnisearchSort.selecting` 공용 전이).
    private func sortButton(title: String, key: OmnisearchSortKey) -> some View {
        Button {
            sort = sort.selecting(key)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sort.key == key {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(sort.key == key ? Color.cmdsAccent : Color.secondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
/// 칼럼 폭 상태 — 세션 한정(팝업이 열려있는 동안만 유지, 저장하지 않음. 스펙 §5.3/§5.4).
private struct OmnisearchColumnWidths {
    var path: CGFloat = 160
    var size: CGFloat = 70
    var modifiedAt: CGFloat = 120
}

/// 칼럼 경계 드래그 핸들 — 왼쪽 칼럼 폭을 늘리고 줄인다(최소 60pt 클램프, 스펙 §5.4).
/// 이름 칼럼은 가변폭이라 자체 핸들이 없다 — 이 핸들로 경로 폭이 바뀌면 이름 칼럼이 남는 공간을
/// 자동으로 채우므로(`.frame(maxWidth: .infinity)`) 사실상 함께 조절된다.
private struct OmnisearchColumnResizeHandle: View {
    @Binding var width: CGFloat
    private let minWidth: CGFloat = 60

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay(Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = width }
                        width = max(minWidth, start + value.translation.width)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                    }
            )
    }
}

private struct OmnisearchRow: View {
    let hit: OmnisearchHit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hit.kind == .file ? "doc.text" : "text.magnifyingglass")
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)

                Text(hit.subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
            }

            Spacer()

            if hit.kind == .content {
                Image(systemName: "arrow.right.to.line")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.cmdsAccentOn.opacity(0.6)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
/// 파일 결과 행 — 이름/경로/크기/수정일 4칸(스펙 §5.4). 표시만 담당 — 클릭·호버·선택 강조는
/// `OmnisearchRow`와 마찬가지로 `ForEach` 레벨에서 배선(회귀 위험 최소화, 설계 §4 결정).
private struct OmnisearchFileRow: View {
    let hit: OmnisearchHit
    let isSelected: Bool
    let columnWidths: OmnisearchColumnWidths

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .secondary)

                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(hit.subtitle)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                .frame(width: columnWidths.path, alignment: .leading)

            Text(FileInfoService.formatSize(hit.sizeBytes ?? 0))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                .frame(width: columnWidths.size, alignment: .trailing)

            Text(hit.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                .frame(width: columnWidths.modifiedAt, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

#if !SWIFT_PACKAGE
#Preview {
    OmnisearchView()
        .environment(AppState())
}
#endif
