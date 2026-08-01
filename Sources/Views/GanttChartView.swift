import SwiftUI

/// "Todoist 할일" 탭의 간트차트 — 레고 요청("간트차트처럼 보고 싶다") 반영. 모든 막대는
/// 오늘에서 시작해 마감일까지 이어지고(§`GanttLayout`), 가로 범위는 마감일 있는 할일 중
/// 가장 늦은 날짜까지 자동으로 잡되 오늘부터 6개월까지만 잡는다. 마감일이 6개월을 넘거나
/// 아예 없는 할일은 이 차트에 안 나온다(호출부가 걸러서 목록으로 따로 보여준다).
/// 가로축에는 눈금선(12주 이내면 주 단위·그보다 길면 월 단위, §`GanttLayout.axis`)을 깔아
/// 막대 길이가 "언제까지"인지 눈으로 읽히게 한다.
/// 스크롤은 호출부(`TaskListView`)가 한 번에 감싸므로 여기선 하지 않는다.
struct GanttChartView: View {
    let tasks: [TodoistTask]
    let today: Date
    let onComplete: (TodoistTask) -> Void

    /// 행 안에서 막대가 그려지는 칸의 좌우에 붙는 고정 폭들 — 눈금 라벨을 막대 칸과 정확히
    /// 맞추려고 헤더도 같은 값을 쓴다.
    private enum Metrics {
        static let checkColumn: CGFloat = 18
        static let titleColumn: CGFloat = 140
        static let dateColumn: CGFloat = 64
        static let spacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 6
        static let barHeight: CGFloat = 10
    }

    private var rangeEnd: Date {
        GanttLayout.rangeEnd(dueDates: tasks.compactMap { $0.due?.parsedDate }, today: today)
    }

    private var axis: GanttLayout.Axis {
        GanttLayout.axis(today: today, rangeEnd: rangeEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            axisHeader
            ForEach(tasks) { task in
                row(for: task)
            }
        }
    }

    // MARK: - 가로축 헤더(눈금 날짜)

    private var axisHeader: some View {
        let axis = axis
        return HStack(spacing: Metrics.spacing) {
            Color.clear.frame(width: Metrics.checkColumn, height: 1)
            Text("오늘")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: Metrics.titleColumn, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(axis.ticks.enumerated()), id: \.element.id) { index, tick in
                        if showsLabel(at: index, in: axis) {
                            Text(label(for: tick, unit: axis.unit))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: geo.size.width * tick.fraction + 2)
                        }
                    }
                }
            }
            .frame(height: 12)

            Color.clear.frame(width: Metrics.dateColumn, height: 1)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
    }

    /// 눈금이 많으면 라벨을 한 칸 걸러 하나만 — 글자끼리 겹치지 않게.
    private func showsLabel(at index: Int, in axis: GanttLayout.Axis) -> Bool {
        axis.ticks.count <= 8 || index % 2 == 0
    }

    private func label(for tick: GanttLayout.Tick, unit: GanttLayout.TickUnit) -> String {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: tick.date)
        switch unit {
        case .month:
            return "\(month)월"
        case .week:
            return "\(month)/\(calendar.component(.day, from: tick.date))"
        }
    }

    // MARK: - 할일 한 줄

    private func row(for task: TodoistTask) -> some View {
        let due = task.due?.parsedDate ?? today
        let overdue = GanttLayout.isOverdue(due: due, today: today)
        let fraction = overdue ? 0.0 : GanttLayout.barFraction(today: today, due: due, rangeEnd: rangeEnd)
        let ticks = axis.ticks

        return HStack(spacing: Metrics.spacing) {
            Button {
                onComplete(task)
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)
            .frame(width: Metrics.checkColumn, alignment: .leading)

            Text(task.content)
                .font(.caption)
                .lineLimit(1)
                .frame(width: Metrics.titleColumn, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    gridLines(ticks: ticks, width: geo.size.width)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(overdue ? Color.red : Color.accentColor)
                        .frame(width: max(geo.size.width * fraction, 6), height: Metrics.barHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Metrics.barHeight)

            Text(task.due?.string ?? "")
                .font(.caption2)
                .foregroundStyle(overdue ? .red : .secondary)
                .frame(width: Metrics.dateColumn, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, Metrics.horizontalPadding)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 막대 뒤에 깔리는 세로 눈금선 — 막대와 같은 칸(GeometryReader) 안에서 그려 헤더 라벨과 어긋나지 않는다.
    private func gridLines(ticks: [GanttLayout.Tick], width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(ticks) { tick in
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: Metrics.barHeight)
                    .offset(x: width * tick.fraction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
