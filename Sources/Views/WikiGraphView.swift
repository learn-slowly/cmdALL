import SwiftUI

/// 위키 관계도 화면(계획 §관계도 화면) — 점=글, 선=링크(임베드는 점선). Canvas 자체 렌더 +
/// 결정론적 레이아웃(새 패키지 의존성 0). 시작 포커스·절단·해석 계약은 모두
/// `AppState+WikiGraph`/`WikiGraphBuilder`/`WikiGraphLayout`이 맡고, 이 뷰는 스냅샷만 그린다.
struct WikiGraphView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedNodeID: String?
    @State private var searchQuery = ""
    @State private var scale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    /// 핀치 제스처 하나가 시작될 때의 배율 — 이게 없으면 제스처가 끝났다 다시 시작할 때마다
    /// SwiftUI가 주는 상대 배율(1부터 다시 시작)로 스케일을 덮어써 방금 확대한 게 도로 풀렸다.
    @State private var magnifyBaseScale: CGFloat = 1
    /// 화면 중앙 기준 확대/축소를 계산하려면 캔버스의 실제 픽셀 크기가 필요하다.
    @State private var canvasSize: CGSize = .zero
    /// 점 끌기(레고님 요청, 옵시디언 그래프 참고) — 끌어서 옮긴 점은 원래 계산 자리 대신
    /// 이 자리에 그린다. 다시 불러오면 비운다.
    @State private var nodePositionOverrides: [String: CGPoint] = [:]
    @State private var draggingNodeID: String?
    /// 드래그 제스처 하나당 "점을 잡았는지 캔버스를 미는지"를 한 번만 판정하기 위한 플래그.
    @State private var dragTargetResolved = false
    /// 끌기 시작 시점의 잡은 점 자리 — 바로 이웃 점들이 "얼마나 따라올지"를 매 프레임
    /// 시작점 기준으로 다시 계산해 밀림이 누적되지 않게 한다(레고님 요청: 옆 점도 살짝 딸려오게).
    @State private var dragOriginPosition: CGPoint?
    @State private var neighborOriginPositions: [String: CGPoint] = [:]
    /// 잡은 점이 움직인 만큼의 이 비율만큼만 이웃이 딸려온다 — 1.0이면 통째로 따라와
    /// 그래프가 깨지므로 "살짝"에 맞춰 낮게 잡는다.
    private static let neighborPullFactor: CGFloat = 0.18
    @State private var detailSheet: DetailSheet?
    /// 폴더별 보이기/숨기기 필터(레고님 요청 "필터 기능도"). 화면 세션 동안만 기억 —
    /// 검색어(searchQuery)와 같은 관례, 다시 열면 전체 보임으로 시작.
    @State private var hiddenFolders: Set<String> = []
    private static let minScale: CGFloat = 0.2
    private static let maxScale: CGFloat = 3.0

    private enum DetailSheet: Identifiable {
        case unresolved, ambiguous
        var id: Self { self }
    }

    private var snapshot: WikiGraphSnapshot? { appState.wikiGraphSnapshot }

    /// 1-hop 모드일 때 보여줄 노드 id 집합(nil = 전체 보기).
    private var visibleNodeIDs: Set<String>? {
        guard let graph = snapshot?.graph, let focus = appState.wikiGraphFocusedNodeID else { return nil }
        return graph.egoNodes(around: focus)
    }

    private var filteredNodes: [WikiGraphNode] {
        guard let nodes = snapshot?.graph.nodes else { return [] }
        let base = nodes.filter { !hiddenFolders.contains(folder(for: $0.id)) }
        guard !searchQuery.isEmpty else { return base }
        let lowered = searchQuery.lowercased()
        return base.filter { $0.displayName.lowercased().contains(lowered) }
    }

    /// 관계도 색·필터의 분류 단위 = 파일이 든 폴더(문서 id의 상위 경로). 점 색(folderColor)과
    /// 같은 기준을 재사용한다.
    private func folder(for nodeID: String) -> String {
        (nodeID as NSString).deletingLastPathComponent
    }

    /// 지금 그래프에 실제로 등장하는 폴더 목록(정렬) — 사이드바 색·필터 목록에 쓴다.
    private var allFolders: [String] {
        guard let nodes = snapshot?.graph.nodes else { return [] }
        return Set(nodes.map { folder(for: $0.id) }).sorted()
    }

    var body: some View {
        HSplitView {
            sidebarList.frame(minWidth: 220, idealWidth: 260)
            VStack(spacing: 0) {
                toolbarRow
                Divider()
                canvasArea
                Divider()
                statusBar
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
        }
        .task {
            if appState.wikiGraphSnapshot == nil { await appState.loadWikiGraph() }
        }
        .sheet(item: $detailSheet) { kind in
            detailSheetView(kind)
        }
    }

    // MARK: - 좌측 목록

    private var sidebarList: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("검색", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List(filteredNodes, selection: $selectedNodeID) { node in
                Text(node.displayName).tag(node.id as String?)
            }
            .onChange(of: selectedNodeID) { _, newValue in
                if let newValue { appState.wikiGraphFocusedNodeID = newValue }
            }
            if !allFolders.isEmpty {
                Divider()
                categorySection
            }
        }
    }

    // MARK: - 카테고리 색·필터(레고님 요청: 색 커스텀 + 필터 기능)

    private var categorySection: some View {
        DisclosureGroup("카테고리 색·필터") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(allFolders, id: \.self) { folder in
                    WikiGraphFolderRow(
                        label: folder.isEmpty ? "(최상위)" : folder,
                        color: Binding(
                            get: { folderColor(folder) },
                            set: { newColor in
                                appState.settings.wikiGraphFolderColors[folder] = newColor.toHex()
                                appState.saveUserData()
                            }
                        ),
                        isHidden: Binding(
                            get: { hiddenFolders.contains(folder) },
                            set: { hide in
                                if hide { hiddenFolders.insert(folder) } else { hiddenFolders.remove(folder) }
                            }
                        )
                    )
                }
                if !appState.settings.wikiGraphFolderColors.isEmpty {
                    Button("고른 색 초기화") {
                        appState.settings.wikiGraphFolderColors.removeAll()
                        appState.saveUserData()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .font(.caption)
    }

    // MARK: - 툴바(전체/주변만 스위치)

    private var toolbarRow: some View {
        HStack {
            Picker("", selection: Binding(
                get: { appState.wikiGraphFocusedNodeID == nil },
                set: { showFull in
                    if showFull { appState.wikiGraphFocusedNodeID = nil }
                    else if appState.wikiGraphFocusedNodeID == nil { appState.wikiGraphFocusedNodeID = selectedNodeID }
                })) {
                Text("전체 보기").tag(true)
                Text("고른 글 주변만").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Spacer()
            zoomControls
            Spacer()
            Button {
                nodePositionOverrides = [:]
                Task { await appState.loadWikiGraph() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(appState.wikiGraphBusy)
        }
        .padding(10)
    }

    // MARK: - 확대/축소(레고님 피드백 "정신없다" — 화면 중앙 기준 줌 + 버튼/단축키/트랙패드 모두 지원)

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                zoom(to: Self.clampScale(scale / ImageZoomMath.factor))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("축소")

            Text(ImageZoomMath.percentLabel(scale))
                .font(.caption).monospacedDigit()
                .frame(minWidth: 42)
                .contentShape(Rectangle())
                .onTapGesture { resetView() }
                .help("눌러서 원래 크기로")

            Button {
                zoom(to: Self.clampScale(scale * ImageZoomMath.factor))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help("확대")

            Button {
                resetView()
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("맞춤(원래 크기·가운데로)")
        }
        .buttonStyle(.plain)
    }

    private static func clampScale(_ value: CGFloat) -> CGFloat {
        ImageZoomMath.clamp(value, min: minScale, max: maxScale)
    }

    /// 화면 중앙을 기준으로 확대/축소 — 어느 방향으로 줌해도 보던 자리가 화면 가운데 그대로
    /// 있게 유지한다(예전엔 캔버스 왼쪽위 기준이라 확대할 때마다 그림이 오른쪽아래로 튀어나가
    /// 사용자가 "정신없다"고 느꼈다).
    private func zoom(to newScaleRaw: CGFloat) {
        let newScale = Self.clampScale(newScaleRaw)
        guard canvasSize.width > 0, canvasSize.height > 0, newScale != scale else {
            scale = newScale
            return
        }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let ratio = newScale / scale
        panOffset = CGSize(width: center.x - ratio * (center.x - panOffset.width),
                           height: center.y - ratio * (center.y - panOffset.height))
        dragStartOffset = panOffset
        scale = newScale
    }

    private func resetView() {
        scale = 1
        panOffset = .zero
        dragStartOffset = .zero
        magnifyBaseScale = 1
    }

    // MARK: - 캔버스

    @ViewBuilder
    private var canvasArea: some View {
        if appState.wikiGraphBusy && snapshot == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("글을 읽는 중…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = appState.wikiGraphError {
            Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot, !snapshot.graph.nodes.isEmpty {
            GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                graphCanvas(snapshot)
                if let notice = appState.wikiGraphFocusNotice {
                    Text(notice)
                        .font(.callout).padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
                if snapshot.graph.stats.edgeCount == 0 {
                    VStack {
                        Text("글은 \(snapshot.graph.nodes.count)개 찾았지만 글끼리 이어진 링크를 찾지 못했습니다.")
                        Text("본문에 …[[글 이름]]… 또는 …[보이는 말](파일이름.md)… 형태로 링크를 써보세요.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if visibleNodeIDs == nil && snapshot.graph.nodes.count > 120 {
                    VStack {
                        Spacer()
                        Text("글이 \(snapshot.graph.nodes.count)개라 한눈에 보기 어렵습니다 — 목록에서 글을 골라 주변만 보기를 써보세요")
                            .font(.callout).padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(10)
                    }
                }
                if snapshot.graph.stats.droppedPageCount > 0 {
                    VStack {
                        Spacer()
                        Text("글이 너무 많아 이름순 \(WikiGraphBuilder.pageLimit)개까지만 그렸습니다(남은 글 \(snapshot.graph.stats.droppedPageCount)개).")
                            .font(.caption).padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, 40)
                    }
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newValue in canvasSize = newValue }
            }
        } else if let snapshot, snapshot.graph.nodes.isEmpty {
            Text("위키 폴더에서 글(.md)을 찾지 못했습니다")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func graphCanvas(_ snapshot: WikiGraphSnapshot) -> some View {
        let visible = visibleNodeIDs
        let nodes = snapshot.graph.nodes.filter {
            (visible == nil || visible!.contains($0.id)) && !hiddenFolders.contains(folder(for: $0.id))
        }
        let edges = snapshot.graph.edges.filter {
            (visible == nil || (visible!.contains($0.from) && visible!.contains($0.to)))
                && !hiddenFolders.contains(folder(for: $0.from)) && !hiddenFolders.contains(folder(for: $0.to))
        }
        // 끌어서 옮긴 점은 계산된 자리 대신 이 자리를 쓴다(모델 좌표계, scale·pan 적용 전).
        var positions = snapshot.positions
        for (id, overridden) in nodePositionOverrides where positions[id] != nil {
            positions[id] = overridden
        }

        return Canvas { context, size in
            // 좌표를 우리가 직접 scale·pan으로 계산해서 그린다(예전엔 context.scaleBy로 캔버스
            // 전체를 늘렸는데, Canvas가 Text를 고정 크기로 한 번 래스터화한 뒤 그 비트맵을
            // 늘려 그리는 특성 때문에 확대할수록 글자가 흐려졌다 — 레고님 피드백 "줌인했을 때
            // 해상도가 떨어진다"). 글자는 매번 실제 배율에 맞는 폰트 크기로 다시 그리게 해서
            // 항상 또렷하다(옵시디언 그래프 방식 참고).
            func screenPoint(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * scale + panOffset.width, y: p.y * scale + panOffset.height)
            }

            for edge in edges {
                guard let fromModel = positions[edge.from], let toModel = positions[edge.to] else { continue }
                let from = screenPoint(fromModel)
                let to = screenPoint(toModel)
                let dx = to.x - from.x
                let dy = to.y - from.y
                let length = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let ux = dx / length, uy = dy / length
                let nodeRadius: CGFloat = 5 * scale
                // 도착점 원 가장자리에서 멈춰 화살촉이 노드에 가리지 않게 한다.
                let lineEnd = CGPoint(x: to.x - ux * nodeRadius, y: to.y - uy * nodeRadius)
                var path = Path()
                path.move(to: from)
                path.addLine(to: lineEnd)
                let isEmbed = edge.kinds.contains(.embed)
                context.stroke(path, with: .color(.secondary.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.2, dash: isEmbed ? [4, 3] : []))

                // 방향 화살촉(계획 AC "선 = 가리킴, 화살표로 방향").
                let arrowLength: CGFloat = 7
                let arrowAngle: CGFloat = .pi / 7
                let theta = atan2(uy, ux)
                let p1 = CGPoint(x: lineEnd.x - arrowLength * cos(theta - arrowAngle),
                                 y: lineEnd.y - arrowLength * sin(theta - arrowAngle))
                let p2 = CGPoint(x: lineEnd.x - arrowLength * cos(theta + arrowAngle),
                                 y: lineEnd.y - arrowLength * sin(theta + arrowAngle))
                var arrowPath = Path()
                arrowPath.move(to: lineEnd)
                arrowPath.addLine(to: p1)
                arrowPath.move(to: lineEnd)
                arrowPath.addLine(to: p2)
                context.stroke(arrowPath, with: .color(.secondary.opacity(0.7)), lineWidth: 1.2)
            }
            for node in nodes {
                guard let model = positions[node.id] else { continue }
                let point = screenPoint(model)
                let folder = (node.id as NSString).deletingLastPathComponent
                let color = folderColor(folder)
                let isFocused = node.id == appState.wikiGraphFocusedNodeID
                let radius: CGFloat = (isFocused ? 7 : 5) * scale
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if node.id == draggingNodeID {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                                   with: .color(.primary), lineWidth: 1.5)
                }
                if scale > 0.6 {
                    // 라벨을 점 오른쪽에 왼쪽정렬로 붙인다 — 예전엔 라벨 "중심"을 점 옆자리에
                    // 둬서 이름이 짧으면 점에 걸쳐 보였다(레고님 피드백 "점이 파일명을 가린다").
                    context.draw(Text(node.displayName).font(.system(size: 10 * scale)),
                                at: CGPoint(x: point.x + radius + 3, y: point.y), anchor: .leading)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !dragTargetResolved {
                        dragTargetResolved = true
                        draggingNodeID = nearestNode(to: value.startLocation, in: nodes, positions: positions)
                        if let id = draggingNodeID {
                            dragOriginPosition = positions[id]
                            let neighborIDs = snapshot.graph.egoNodes(around: id).subtracting([id])
                            neighborOriginPositions = neighborIDs.reduce(into: [:]) { acc, neighborID in
                                acc[neighborID] = positions[neighborID]
                            }
                        }
                    }
                    if let id = draggingNodeID {
                        // 점 끌기 — 커서를 모델 좌표로 되돌려서 그 점의 새 자리로 삼는다.
                        let newPos = CGPoint(x: (value.location.x - panOffset.width) / scale,
                                             y: (value.location.y - panOffset.height) / scale)
                        nodePositionOverrides[id] = newPos
                        // 바로 이웃 점들도 살짝 딸려온다(레고님 요청, 옵시디언 그래프 참고) —
                        // 시작점 기준 이동량의 일부만 더해서 통째로 따라오지 않게 한다.
                        if let origin = dragOriginPosition {
                            let delta = CGSize(width: newPos.x - origin.x, height: newPos.y - origin.y)
                            for (neighborID, neighborOrigin) in neighborOriginPositions {
                                nodePositionOverrides[neighborID] = CGPoint(
                                    x: neighborOrigin.x + delta.width * Self.neighborPullFactor,
                                    y: neighborOrigin.y + delta.height * Self.neighborPullFactor)
                            }
                        }
                    } else {
                        panOffset = CGSize(width: dragStartOffset.width + value.translation.width,
                                           height: dragStartOffset.height + value.translation.height)
                    }
                }
                .onEnded { _ in
                    dragTargetResolved = false
                    dragOriginPosition = nil
                    neighborOriginPositions = [:]
                    if draggingNodeID != nil {
                        draggingNodeID = nil
                    } else {
                        dragStartOffset = panOffset
                    }
                }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { value in zoom(to: magnifyBaseScale * value) }
                .onEnded { _ in magnifyBaseScale = scale }
        )
        .onTapGesture { location in
            guard let hit = nearestNode(to: location, in: nodes, positions: positions) else { return }
            appState.openWikiGraphNode(hit)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func nearestNode(to location: CGPoint, in nodes: [WikiGraphNode],
                             positions: [String: CGPoint]) -> String? {
        let adjusted = CGPoint(x: (location.x - panOffset.width) / scale,
                               y: (location.y - panOffset.height) / scale)
        var best: (id: String, distance: CGFloat)?
        for node in nodes {
            guard let point = positions[node.id] else { continue }
            let dx = point.x - adjusted.x
            let dy = point.y - adjusted.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < 14, best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    private func folderColor(_ folder: String) -> Color {
        // 레고님이 직접 고른 색(설정에 저장)이 있으면 그걸 먼저 쓴다.
        if let hex = appState.settings.wikiGraphFolderColors[folder] { return Color(hex: hex) }
        guard !folder.isEmpty else { return .accentColor }
        var hash: UInt64 = 5381
        for byte in folder.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    // MARK: - 상태줄

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let stats = snapshot?.graph.stats {
                Text("글 \(stats.nodeCount)")
                Text("연결 \(stats.edgeCount)")
                Button("못 찾은 링크 \(stats.unresolvedCount)") { detailSheet = .unresolved }
                    .buttonStyle(.plain).foregroundStyle(stats.unresolvedCount > 0 ? .primary : .secondary)
                    .disabled(stats.unresolvedCount == 0)
                if stats.outsideLimitCount > 0 {
                    Text("이번 그림 밖 링크 \(stats.outsideLimitCount)")
                }
                Button("이름 겹침 \(stats.ambiguousCount)") { detailSheet = .ambiguous }
                    .buttonStyle(.plain).foregroundStyle(stats.ambiguousCount > 0 ? .primary : .secondary)
                    .disabled(stats.ambiguousCount == 0)
                if stats.unreadablePageCount > 0 {
                    Text("읽지 못한 파일 \(stats.unreadablePageCount)")
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(10)
    }

    @ViewBuilder
    private func detailSheetView(_ kind: DetailSheet) -> some View {
        let rows: [WikiLinkResolution] = {
            switch kind {
            case .unresolved: return snapshot?.graph.unresolvedLinks ?? []
            case .ambiguous: return snapshot?.graph.ambiguousLinks ?? []
            }
        }()
        NavigationStack {
            List(Array(rows.enumerated()), id: \.offset) { _, resolution in
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolution.fromPage).font(.callout)
                    Text("→ \(resolution.rawTarget)").font(.caption).foregroundStyle(.secondary)
                    if !resolution.candidatePaths.isEmpty {
                        Text(resolution.candidatePaths.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(kind == .unresolved ? "연결 못 찾은 링크" : "이름이 겹치는 링크")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { detailSheet = nil }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// 카테고리(폴더) 한 줄 — 색 고르기 + 보이기/숨기기(레고님 요청: 색 커스텀 + 필터).
struct WikiGraphFolderRow: View {
    let label: String
    @Binding var color: Color
    @Binding var isHidden: Bool

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 18, height: 18)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isHidden ? .secondary : .primary)
            Spacer(minLength: 4)
            Button {
                isHidden.toggle()
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHidden ? .secondary : .primary)
            .help(isHidden ? "다시 보이기" : "숨기기")
        }
    }
}
