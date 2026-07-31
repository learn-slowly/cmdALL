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
    @State private var detailSheet: DetailSheet?
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
        guard !searchQuery.isEmpty else { return nodes }
        let lowered = searchQuery.lowercased()
        return nodes.filter { $0.displayName.lowercased().contains(lowered) }
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
        }
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
        let nodes = snapshot.graph.nodes.filter { visible == nil || visible!.contains($0.id) }
        let edges = snapshot.graph.edges.filter {
            visible == nil || (visible!.contains($0.from) && visible!.contains($0.to))
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
                    }
                    if let id = draggingNodeID {
                        // 점 끌기 — 커서를 모델 좌표로 되돌려서 그 점의 새 자리로 삼는다.
                        nodePositionOverrides[id] = CGPoint(
                            x: (value.location.x - panOffset.width) / scale,
                            y: (value.location.y - panOffset.height) / scale)
                    } else {
                        panOffset = CGSize(width: dragStartOffset.width + value.translation.width,
                                           height: dragStartOffset.height + value.translation.height)
                    }
                }
                .onEnded { _ in
                    dragTargetResolved = false
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
