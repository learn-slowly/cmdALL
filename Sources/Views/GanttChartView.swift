import SwiftUI

/// "Todoist 할일" 탭의 간트차트 — 레고 요청("간트차트처럼 보고 싶다") 반영. 모든 막대는
/// 오늘에서 시작해 마감일까지 이어지고(§`GanttLayout`), 가로 범위는 마감일 있는 할일 중
/// 가장 늦은 날짜까지 자동으로 잡는다. 마감일 없는 할일은 이 차트에 안 나온다(호출부가
/// 걸러서 넘긴다).
struct GanttChartView: View {
    let tasks: [TodoistTask]
    let today: Date
    let onComplete: (TodoistTask) -> Void

    private var rangeEnd: Date {
        GanttLayout.rangeEnd(dueDates: tasks.compactMap { $0.due?.parsedDate }, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            axisHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks) { task in
                        row(for: task)
                    }
                }
            }
        }
    }

    private var axisHeader: some View {
        HStack {
            Text("오늘").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(rangeEnd, style: .date).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 172)   // 왼쪽 제목 칸 폭(140) + 체크 버튼(18) + 간격만큼 밀어 축과 맞춘다.
    }

    private func row(for task: TodoistTask) -> some View {
        let due = task.due?.parsedDate ?? today
        let overdue = GanttLayout.isOverdue(due: due, today: today)
        let fraction = overdue ? 0.0 : GanttLayout.barFraction(today: today, due: due, rangeEnd: rangeEnd)

        return HStack(spacing: 8) {
            Button {
                onComplete(task)
            } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(.plain)

            Text(task.content)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(overdue ? Color.red : Color.accentColor)
                    .frame(width: max(geo.size.width * fraction, 6), height: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 10)

            if let string = task.due?.string {
                Text(string)
                    .font(.caption2)
                    .foregroundStyle(overdue ? .red : .secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
